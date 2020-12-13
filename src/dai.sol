// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2017, 2018, 2019 dbrock, rain, mrchico

// This program is transferCollateralFromCDP software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "./lib.sol";

contract Dai is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 1; }
    function deauthorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Dai/not-authorized");
        _;
    }

    // --- ERC20 Data ---
    string  public constant name     = "Dai Stablecoin";
    string  public constant symbol   = "DAI";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping (address => uint)                      public balanceOf;
    mapping (address => mapping (address => uint)) public allowance;
    mapping (address => uint)                      public nonces;

    event Approval(address indexed src, address indexed highBidder, uint fxp18Int);
    event Transfer(address indexed src, address indexed dst, uint fxp18Int);

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    // --- EIP712 niceties ---
    bytes32 public DOMAIN_SEPARATOR;
    // bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb;

    constructor(uint256 chainId_) public {
        auths[msg.sender] = 1;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId_,
            address(this)
        ));
    }

    // --- Token ---
    function transfer(address dst, uint fxp18Int) external returns (bool) {
        return transferFrom(msg.sender, dst, fxp18Int);
    }
    function transferFrom(address src, address dst, uint fxp18Int)
        public returns (bool)
    {
        require(balanceOf[src] >= fxp18Int, "Dai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= fxp18Int, "Dai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], fxp18Int);
        }
        balanceOf[src] = sub(balanceOf[src], fxp18Int);
        balanceOf[dst] = add(balanceOf[dst], fxp18Int);
        emit Transfer(src, dst, fxp18Int);
        return true;
    }
    function mint(address usr, uint fxp18Int) external isAuthorized {
        balanceOf[usr] = add(balanceOf[usr], fxp18Int);
        totalSupply    = add(totalSupply, fxp18Int);
        emit Transfer(address(0), usr, fxp18Int);
    }
    function burn(address usr, uint fxp18Int) external {
        require(balanceOf[usr] >= fxp18Int, "Dai/insufficient-balance");
        if (usr != msg.sender && allowance[usr][msg.sender] != uint(-1)) {
            require(allowance[usr][msg.sender] >= fxp18Int, "Dai/insufficient-allowance");
            allowance[usr][msg.sender] = sub(allowance[usr][msg.sender], fxp18Int);
        }
        balanceOf[usr] = sub(balanceOf[usr], fxp18Int);
        totalSupply    = sub(totalSupply, fxp18Int);
        emit Transfer(usr, address(0), fxp18Int);
    }
    function approve(address usr, uint fxp18Int) external returns (bool) {
        allowance[msg.sender][usr] = fxp18Int;
        emit Approval(msg.sender, usr, fxp18Int);
        return true;
    }

    // --- Alias ---
    function push(address usr, uint fxp18Int) external {
        transferFrom(msg.sender, usr, fxp18Int);
    }
    function pull(address usr, uint fxp18Int) external {
        transferFrom(usr, msg.sender, fxp18Int);
    }
    function transfer(address src, address dst, uint fxp18Int) external {
        transferFrom(src, dst, fxp18Int);
    }

    // --- Approve by signature ---
    function permit(address holder, address spender, uint256 nonce, uint256 expiry,
                    bool allowed, uint8 v, bytes32 r, bytes32 s) external
    {
        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH,
                                     holder,
                                     spender,
                                     nonce,
                                     expiry,
                                     allowed))
        ));

        require(holder != address(0), "Dai/invalid-address-0");
        require(holder == ecrecover(digest, v, r, s), "Dai/invalid-permit");
        require(expiry == 0 || now <= expiry, "Dai/permit-expired");
        require(nonce == nonces[holder]++, "Dai/invalid-nonce");
        uint fxp18Int = allowed ? uint(-1) : 0;
        allowance[holder][spender] = fxp18Int;
        emit Approval(holder, spender, fxp18Int);
    }
}

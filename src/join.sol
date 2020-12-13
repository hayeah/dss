// SPDX-License-Identifier: AGPL-3.0-or-later

/// deposit.sol -- Basic token adapters

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
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

interface CollateralTokensInterface {
    function decimals() external view returns (uint);
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

interface DSTokenLike {
    function mint(address,uint) external;
    function burn(address,uint) external;
}

interface CDPCoreInterface {
    function modifyUsersCollateralBalance(bytes32,address,int) external;
    function transfer(address,address,uint) external;
}

/*
    Here we provide *adapters* to connect the CDPCore to arbitrary external
    token implementations, creating a bounded context for the CDPCore. The
    adapters here are provided as working examples:

      - `GemJoin`: For well behaved ERC20 tokens, with simple transfer
                   semantics.

      - `ETHJoin`: For native Ether.

      - `DaiJoin`: For connecting internal Dai balances to an external
                   `DSToken` implementation.

    In practice, adapter implementations will be varied and specific to
    individual collateral types, accounting for different transfer
    semantics and token standards.

    Adapters need to implement two basic methods:

      - `deposit`: enter collateral into the system
      - `exit`: remove collateral from the system

*/

contract GemJoin is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "GemJoin/not-authorized");
        _;
    }

    CDPCoreInterface public cdpCore;   // CDP Engine
    bytes32 public collateralType;   // Collateral Type
    CollateralTokensInterface public collateralToken;
    uint    public dec;
    uint    public isAlive;  // Active Flag

    constructor(address core_, bytes32 ilk_, address collateralToken_) public {
        auths[msg.sender] = 1;
        isAlive = 1;
        cdpCore = CDPCoreInterface(core_);
        collateralType = ilk_;
        collateralToken = CollateralTokensInterface(collateralToken_);
        dec = collateralToken.decimals();
    }
    function disable() external note isAuthorized {
        isAlive = 0;
    }
    function deposit(address usr, uint fxp18Int) external note {
        require(isAlive == 1, "GemJoin/not-isAlive");
        require(int(fxp18Int) >= 0, "GemJoin/overflow");
        cdpCore.modifyUsersCollateralBalance(collateralType, usr, int(fxp18Int));
        require(collateralToken.transferFrom(msg.sender, address(this), fxp18Int), "GemJoin/failed-transfer");
    }
    function exit(address usr, uint fxp18Int) external note {
        require(fxp18Int <= 2 ** 255, "GemJoin/overflow");
        cdpCore.modifyUsersCollateralBalance(collateralType, msg.sender, -int(fxp18Int));
        require(collateralToken.transfer(usr, fxp18Int), "GemJoin/failed-transfer");
    }
}

contract DaiJoin is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "DaiJoin/not-authorized");
        _;
    }

    CDPCoreInterface public cdpCore;      // CDP Engine
    DSTokenLike public dai;  // Stablecoin Token
    uint    public isAlive;     // Active Flag

    constructor(address core_, address dai_) public {
        auths[msg.sender] = 1;
        isAlive = 1;
        cdpCore = CDPCoreInterface(core_);
        dai = DSTokenLike(dai_);
    }
    function disable() external note isAuthorized {
        isAlive = 0;
    }
    uint constant ONE = 10 ** 27;
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function deposit(address usr, uint fxp18Int) external note {
        cdpCore.transfer(address(this), usr, mul(ONE, fxp18Int));
        dai.burn(msg.sender, fxp18Int);
    }
    function exit(address usr, uint fxp18Int) external note {
        require(isAlive == 1, "DaiJoin/not-isAlive");
        cdpCore.transfer(msg.sender, address(this), mul(ONE, fxp18Int));
        dai.mint(usr, fxp18Int);
    }
}

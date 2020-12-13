// SPDX-License-Identifier: AGPL-3.0-or-later

/// maxDaiPerUnitOfCollateral.sol -- Spotter

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

interface CDPCoreInterface {
    function changeConfig(bytes32, bytes32, uint) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

contract Spotter is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 1;  }
    function deauthorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Spotter/not-authorized");
        _;
    }

    // --- Data ---
    struct CollateralType {
        PipLike pip;  // Price Feed
        uint256 mat;  // Liquidation ratio [fxp27Int]
    }

    mapping (bytes32 => CollateralType) public collateralTypes;

    CDPCoreInterface public cdpCore;  // CDP Engine
    uint256 public par;  // ref per dai [fxp27Int]

    uint256 public isAlive;

    // --- Events ---
    event Poke(
      bytes32 collateralType,
      bytes32 val,  // [fxp18Int]
      uint256 maxDaiPerUnitOfCollateral  // [fxp27Int]
    );

    // --- Init ---
    constructor(address core_) public {
        auths[msg.sender] = 1;
        cdpCore = CDPCoreInterface(core_);
        par = ONE;
        isAlive = 1;
    }

    // --- Math ---
    uint constant ONE = 10 ** 27;

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, ONE) / y;
    }

    // --- Administration ---
    function changeConfig(bytes32 collateralType, bytes32 what, address pip_) external note isAuthorized {
        require(isAlive == 1, "Spotter/not-isAlive");
        if (what == "pip") collateralTypes[collateralType].pip = PipLike(pip_);
        else revert("Spotter/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        require(isAlive == 1, "Spotter/not-isAlive");
        if (what == "par") par = data;
        else revert("Spotter/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 collateralType, bytes32 what, uint data) external note isAuthorized {
        require(isAlive == 1, "Spotter/not-isAlive");
        if (what == "mat") collateralTypes[collateralType].mat = data;
        else revert("Spotter/changeConfig-unrecognized-param");
    }

    // --- Update value ---
    function poke(bytes32 collateralType) external {
        (bytes32 val, bool has) = collateralTypes[collateralType].pip.peek();
        uint256 maxDaiPerUnitOfCollateral = has ? rdiv(rdiv(mul(uint(val), 10 ** 9), par), collateralTypes[collateralType].mat) : 0;
        cdpCore.changeConfig(collateralType, "maxDaiPerUnitOfCollateral", maxDaiPerUnitOfCollateral);
        emit Poke(collateralType, val, maxDaiPerUnitOfCollateral);
    }

    function disable() external note isAuthorized {
        isAlive = 0;
    }
}

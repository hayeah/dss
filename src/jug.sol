// SPDX-License-Identifier: AGPL-3.0-or-later

/// stabilityFeeDatabase.sol -- Dai Lending Rate

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

interface CDPCoreInterface {
    function collateralTypes(bytes32) external returns (
        uint256 totalStablecoinDebt,   // [fxp18Int]
        uint256 debtMultiplierIncludingStabilityFee   // [fxp27Int]
    );
    function changeDebtMultiplier(bytes32,address,int) external;
}

contract Jug is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Jug/not-authorized");
        _;
    }

    // --- Data ---
    struct CollateralType {
        uint256 duty;  // Collateral-specific, per-second stability fee contribution [fxp27Int]
        uint256  collateralTypeLastStabilityFeeCollectionTimestamp;  // Time of last increaseStabilityFee [unix epoch time]
    }

    mapping (bytes32 => CollateralType) public collateralTypes;
    CDPCoreInterface                  public cdpCore;   // CDP Engine
    address                  public settlement;   // Debt Engine
    uint256                  public base;  // Global, per-second stability fee contribution [fxp27Int]

    // --- Init ---
    constructor(address core_) public {
        auths[msg.sender] = 1;
        cdpCore = CDPCoreInterface(core_);
    }

    // --- Math ---
    function rpow(uint x, uint n, uint b) internal pure returns (uint z) {
      assembly {
        switch x case 0 {switch n case 0 {z := b} default {z := 0}}
        default {
          switch mod(n, 2) case 0 { z := b } default { z := x }
          let half := div(b, 2)  // for rounding.
          for { n := div(n, 2) } n { n := div(n,2) } {
            let xx := mul(x, x)
            if iszero(eq(div(xx, x), x)) { revert(0,0) }
            let xxRound := add(xx, half)
            if lt(xxRound, xx) { revert(0,0) }
            x := div(xxRound, b)
            if mod(n,2) {
              let zx := mul(z, x)
              if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
              let zxRound := add(zx, half)
              if lt(zxRound, zx) { revert(0,0) }
              z := div(zxRound, b)
            }
          }
        }
      }
    }
    uint256 constant ONE = 10 ** 27;
    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }
    function diff(uint x, uint y) internal pure returns (int z) {
        z = int(x) - int(y);
        require(int(x) >= 0 && int(y) >= 0);
    }
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / ONE;
    }

    // --- Administration ---
    function createNewCollateralType(bytes32 collateralType) external note isAuthorized {
        CollateralType storage i = collateralTypes[collateralType];
        require(i.duty == 0, "Jug/collateralType-already-createNewCollateralType");
        i.duty = ONE;
        i.collateralTypeLastStabilityFeeCollectionTimestamp  = now;
    }
    function changeConfig(bytes32 collateralType, bytes32 what, uint data) external note isAuthorized {
        require(now == collateralTypes[collateralType].collateralTypeLastStabilityFeeCollectionTimestamp, "Jug/collateralTypeLastStabilityFeeCollectionTimestamp-not-updated");
        if (what == "duty") collateralTypes[collateralType].duty = data;
        else revert("Jug/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        if (what == "base") base = data;
        else revert("Jug/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, address data) external note isAuthorized {
        if (what == "settlement") settlement = data;
        else revert("Jug/changeConfig-unrecognized-param");
    }

    // --- Stability Fee Collection ---
    function increaseStabilityFee(bytes32 collateralType) external note returns (uint debtMultiplierIncludingStabilityFee) {
        require(now >= collateralTypes[collateralType].collateralTypeLastStabilityFeeCollectionTimestamp, "Jug/invalid-now");
        (, uint prev) = cdpCore.collateralTypes(collateralType);
        debtMultiplierIncludingStabilityFee = rmul(rpow(add(base, collateralTypes[collateralType].duty), now - collateralTypes[collateralType].collateralTypeLastStabilityFeeCollectionTimestamp, ONE), prev);
        cdpCore.changeDebtMultiplier(collateralType, settlement, diff(debtMultiplierIncludingStabilityFee, prev));
        collateralTypes[collateralType].collateralTypeLastStabilityFeeCollectionTimestamp = now;
    }
}

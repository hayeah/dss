// SPDX-License-Identifier: AGPL-3.0-or-later

/// pot.sol -- Dai Savings Rate

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

/*
   "Savings Dai" is obtained when Dai is deposited into
   this contract. Each "Savings Dai" accrues Dai interest
   at the "Dai Savings Rate".

   This contract does not implement a user tradeable token
   and is intended to be used with adapters.

         --- `save` your `dai` in the `pot` ---

   - `daiSavingRate`: the Dai Savings Rate
   - `daiSavings`: user balance of Savings Dai

   - `deposit`: start saving some dai
   - `exit`: remove some dai
   - `increaseStabilityFee`: perform debtMultiplierIncludingStabilityFee collection

*/

interface CDPCoreInterface {
    function transfer(address,address,uint256) external;
    function issueBadDebt(address,address,uint256) external;
}

contract Savings is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 1; }
    function deauthorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Savings/not-authorized");
        _;
    }

    // --- Data ---
    mapping (address => uint256) public daiSavings;  // Normalised Savings Dai [fxp18Int]

    uint256 public totalDaiSavings;   // Total Normalised Savings Dai  [fxp18Int]
    uint256 public daiSavingRate;   // The Dai Savings Rate          [fxp27Int]
    uint256 public rateAccum;   // The Rate Accumulator          [fxp27Int]

    CDPCoreInterface public cdpCore;   // CDP Engine
    address public settlement;   // Debt Engine
    uint256 public collateralTypeLastStabilityFeeCollectionTimestamp;   // Time of last increaseStabilityFee     [unix epoch time]

    uint256 public isAlive;  // Active Flag

    // --- Init ---
    constructor(address core_) public {
        auths[msg.sender] = 1;
        cdpCore = CDPCoreInterface(core_);
        daiSavingRate = ONE;
        rateAccum = ONE;
        collateralTypeLastStabilityFeeCollectionTimestamp = now;
        isAlive = 1;
    }

    // --- Math ---
    uint256 constant ONE = 10 ** 27;
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / ONE;
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function changeConfig(bytes32 what, uint256 data) external note isAuthorized {
        require(isAlive == 1, "Savings/not-isAlive");
        require(now == collateralTypeLastStabilityFeeCollectionTimestamp, "Savings/collateralTypeLastStabilityFeeCollectionTimestamp-not-updated");
        if (what == "daiSavingRate") daiSavingRate = data;
        else revert("Savings/changeConfig-unrecognized-param");
    }

    function changeConfig(bytes32 what, address highBidder) external note isAuthorized {
        if (what == "settlement") settlement = highBidder;
        else revert("Savings/changeConfig-unrecognized-param");
    }

    function disable() external note isAuthorized {
        isAlive = 0;
        daiSavingRate = ONE;
    }

    // --- Savings Rate Accumulation ---
    function increaseStabilityFee() external note returns (uint tmp) {
        require(now >= collateralTypeLastStabilityFeeCollectionTimestamp, "Savings/invalid-now");
        tmp = rmul(rpow(daiSavingRate, now - collateralTypeLastStabilityFeeCollectionTimestamp, ONE), rateAccum);
        uint chi_ = sub(tmp, rateAccum);
        rateAccum = tmp;
        collateralTypeLastStabilityFeeCollectionTimestamp = now;
        cdpCore.issueBadDebt(address(settlement), address(this), mul(totalDaiSavings, chi_));
    }

    // --- Savings Dai Management ---
    function deposit(uint fxp18Int) external note {
        require(now == collateralTypeLastStabilityFeeCollectionTimestamp, "Savings/collateralTypeLastStabilityFeeCollectionTimestamp-not-updated");
        daiSavings[msg.sender] = add(daiSavings[msg.sender], fxp18Int);
        totalDaiSavings             = add(totalDaiSavings,             fxp18Int);
        cdpCore.transfer(msg.sender, address(this), mul(rateAccum, fxp18Int));
    }

    function exit(uint fxp18Int) external note {
        daiSavings[msg.sender] = sub(daiSavings[msg.sender], fxp18Int);
        totalDaiSavings             = sub(totalDaiSavings,             fxp18Int);
        cdpCore.transfer(address(this), msg.sender, mul(rateAccum, fxp18Int));
    }
}

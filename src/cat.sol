// SPDX-License-Identifier: AGPL-3.0-or-later

/// cat.sol -- Dai liquidation module

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

interface AuctionStarter {
    function startAuction(address cdp, address incomeRecipient, uint256 tab, uint256 lot, uint256 bid)
        external returns (uint256);
}

interface CDPCoreInterface {
    function collateralTypes(bytes32) external view returns (
        uint256 totalStablecoinDebt,  // [fxp18Int]
        uint256 debtMultiplierIncludingStabilityFee, // [fxp27Int]
        uint256 maxDaiPerUnitOfCollateral, // [fxp27Int]
        uint256 debtCeiling, // [fxp45Int]
        uint256 dust  // [fxp45Int]
    );
    function cdps(bytes32,address) external view returns (
        uint256 collateralBalance,  // [fxp18Int]
        uint256 stablecoinDebt   // [fxp18Int]
    );
    function liquidateCDP(bytes32,address,address,address,int256,int256) external;
    function grantAccess(address) external;
    function revokeAccess(address) external;
}

interface SettlementInterface {
    function addDebtToDebtQueue(uint256) external;
}

contract Liquidation is LibNote {
    // --- Auth ---
    mapping (address => uint256) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Liquidation/not-authorized");
        _;
    }

    // --- Data ---
    struct CollateralType {
        address collateralForDaiAuction;  // Liquidator
        uint256 liquidationPenalty;  // Liquidation Penalty  [fxp18Int]
        uint256 dunk;  // Liquidation Quantity [fxp45Int]
    }

    mapping (bytes32 => CollateralType) public collateralTypes;

    uint256 public isAlive;   // Active Flag
    CDPCoreInterface public cdpCore;    // CDP Engine
    SettlementInterface public settlement;    // Debt Engine
    uint256 public box;    // Max Dai out for liquidation        [fxp45Int]
    uint256 public litter; // Balance of Dai out for liquidation [fxp45Int]

    // --- Events ---
    event LiquidateCdp(
      bytes32 indexed collateralType,
      address indexed cdp,
      uint256 collateralBalance,
      uint256 stablecoinDebt,
      uint256 tab,
      address collateralForDaiAuction,
      uint256 id
    );

    // --- Init ---
    constructor(address core_) public {
        auths[msg.sender] = 1;
        cdpCore = CDPCoreInterface(core_);
        isAlive = 1;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (x > y) { z = y; } else { z = x; }
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function changeConfig(bytes32 what, address data) external note isAuthorized {
        if (what == "settlement") settlement = SettlementInterface(data);
        else revert("Liquidation/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, uint256 data) external note isAuthorized {
        if (what == "box") box = data;
        else revert("Liquidation/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 collateralType, bytes32 what, uint256 data) external note isAuthorized {
        if (what == "liquidationPenalty") collateralTypes[collateralType].liquidationPenalty = data;
        else if (what == "dunk") collateralTypes[collateralType].dunk = data;
        else revert("Liquidation/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 collateralType, bytes32 what, address collateralForDaiAuction) external note isAuthorized {
        if (what == "collateralForDaiAuction") {
            cdpCore.revokeAccess(collateralTypes[collateralType].collateralForDaiAuction);
            collateralTypes[collateralType].collateralForDaiAuction = collateralForDaiAuction;
            cdpCore.grantAccess(collateralForDaiAuction);
        }
        else revert("Liquidation/changeConfig-unrecognized-param");
    }

    // --- CDP Liquidation ---
    function liquidateCdp(bytes32 collateralType, address cdp) external returns (uint256 id) {
        (,uint256 debtMultiplierIncludingStabilityFee,uint256 maxDaiPerUnitOfCollateral,,uint256 dust) = cdpCore.collateralTypes(collateralType);
        (uint256 collateralBalance, uint256 stablecoinDebt) = cdpCore.cdps(collateralType, cdp);

        require(isAlive == 1, "Liquidation/not-isAlive");
        require(maxDaiPerUnitOfCollateral > 0 && mul(collateralBalance, maxDaiPerUnitOfCollateral) < mul(stablecoinDebt, debtMultiplierIncludingStabilityFee), "Liquidation/not-unsafe");

        CollateralType memory milk = collateralTypes[collateralType];
        uint256 changeInDebt;
        {
            uint256 room = sub(box, litter);

            // test whether the remaining space in the litterbox is dusty
            require(litter < box && room >= dust, "Liquidation/liquidation-limit-hit");

            changeInDebt = min(stablecoinDebt, mul(min(milk.dunk, room), WAD) / debtMultiplierIncludingStabilityFee / milk.liquidationPenalty);
        }

        uint256 changeInCollateral = min(collateralBalance, mul(collateralBalance, changeInDebt) / stablecoinDebt);

        require(changeInDebt >  0      && changeInCollateral >  0     , "Liquidation/null-auction");
        require(changeInDebt <= 2**255 && changeInCollateral <= 2**255, "Liquidation/overflow"    );

        // This may leave the CDP in a dusty state
        cdpCore.liquidateCDP(
            collateralType, cdp, address(this), address(settlement), -int256(changeInCollateral), -int256(changeInDebt)
        );
        settlement.addDebtToDebtQueue(mul(changeInDebt, debtMultiplierIncludingStabilityFee));

        { // Avoid stack too deep
            // This calcuation will overflow if changeInDebt*debtMultiplierIncludingStabilityFee exceeds ~10^14,
            // i.e. the maximum dunk is roughly 100 trillion DAI.
            uint256 tab = mul(mul(changeInDebt, debtMultiplierIncludingStabilityFee), milk.liquidationPenalty) / WAD;
            litter = add(litter, tab);

            id = AuctionStarter(milk.collateralForDaiAuction).startAuction({
                cdp: cdp,
                incomeRecipient: address(settlement),
                tab: tab,
                lot: changeInCollateral,
                bid: 0
            });
        }

        emit LiquidateCdp(collateralType, cdp, changeInCollateral, changeInDebt, mul(changeInDebt, debtMultiplierIncludingStabilityFee), milk.collateralForDaiAuction, id);
    }

    function claw(uint256 fxp45Int) external note isAuthorized {
        litter = sub(litter, fxp45Int);
    }

    function disable() external note isAuthorized {
        isAlive = 0;
    }
}

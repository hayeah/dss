// SPDX-License-Identifier: AGPL-3.0-or-later

/// settlement.sol -- Dai settlement module

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

interface BadDebtAuctionInterface {
    function startAuction(address incomeRecipient, uint lot, uint bid) external returns (uint);
    function disable() external;
    function isAlive() external returns (uint);
}

interface SurplusAuctionInterface {
    function startAuction(uint lot, uint bid) external returns (uint);
    function disable(uint) external;
    function isAlive() external returns (uint);
}

interface CDPCoreInterface {
    function dai (address) external view returns (uint);
    function badDebt (address) external view returns (uint);
    function settleDebtUsingSurplus(uint256) external;
    function grantAccess(address) external;
    function revokeAccess(address) external;
}

contract Settlement is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { require(isAlive == 1, "Settlement/not-isAlive"); auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Settlement/not-authorized");
        _;
    }

    // --- Data ---
    CDPCoreInterface public cdpCore;        // CDP Engine
    SurplusAuctionInterface public surplusAuction;   // Surplus Auction House
    BadDebtAuctionInterface public badDebtAuction;   // Debt Auction House

    mapping (uint256 => uint256) public badDebt;  // debt queue
    uint256 public totalDebtInDebtQueue;   // Queued debt            [fxp45Int]
    uint256 public totalOnAuctionDebt;   // On-auction debt        [fxp45Int]

    uint256 public debtQueueLength;  // Flop delay             [seconds]
    uint256 public dump;  // Flop initial lot size  [fxp18Int]
    uint256 public debtAuctionLotSize;  // Flop fixed bid size    [fxp45Int]

    uint256 public surplusAuctionLotSize;  // Flap fixed lot size    [fxp45Int]
    uint256 public surplusAuctionBuffer;  // Surplus buffer         [fxp45Int]

    uint256 public isAlive;  // Active Flag

    // --- Init ---
    constructor(address core_, address surplusAuction_, address badDebtAuction_) public {
        auths[msg.sender] = 1;
        cdpCore     = CDPCoreInterface(core_);
        surplusAuction = SurplusAuctionInterface(surplusAuction_);
        badDebtAuction = BadDebtAuctionInterface(badDebtAuction_);
        cdpCore.grantAccess(surplusAuction_);
        isAlive = 1;
    }

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function min(uint x, uint y) internal pure returns (uint z) {
        return x <= y ? x : y;
    }

    // --- Administration ---
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        if (what == "debtQueueLength") debtQueueLength = data;
        else if (what == "surplusAuctionLotSize") surplusAuctionLotSize = data;
        else if (what == "debtAuctionLotSize") debtAuctionLotSize = data;
        else if (what == "dump") dump = data;
        else if (what == "surplusAuctionBuffer") surplusAuctionBuffer = data;
        else revert("Settlement/changeConfig-unrecognized-param");
    }

    function changeConfig(bytes32 what, address data) external note isAuthorized {
        if (what == "surplusAuction") {
            cdpCore.revokeAccess(address(surplusAuction));
            surplusAuction = SurplusAuctionInterface(data);
            cdpCore.grantAccess(data);
        }
        else if (what == "badDebtAuction") badDebtAuction = BadDebtAuctionInterface(data);
        else revert("Settlement/changeConfig-unrecognized-param");
    }

    // Push to debt-queue
    function addDebtToDebtQueue(uint tab) external note isAuthorized {
        badDebt[now] = add(badDebt[now], tab);
        totalDebtInDebtQueue = add(totalDebtInDebtQueue, tab);
    }
    // Pop from debt-queue
    function removeDebtFromDebtQueue(uint era) external note {
        require(add(era, debtQueueLength) <= now, "Settlement/debtQueueLength-not-finished");
        totalDebtInDebtQueue = sub(totalDebtInDebtQueue, badDebt[era]);
        badDebt[era] = 0;
    }

    // Debt settlement
    function settleDebtUsingSurplus(uint fxp45Int) external note {
        require(fxp45Int <= cdpCore.dai(address(this)), "Settlement/insufficient-surplus");
        require(fxp45Int <= sub(sub(cdpCore.badDebt(address(this)), totalDebtInDebtQueue), totalOnAuctionDebt), "Settlement/insufficient-debt");
        cdpCore.settleDebtUsingSurplus(fxp45Int);
    }
    function settleOnAuctionDebtUsingSurplus(uint fxp45Int) external note {
        require(fxp45Int <= totalOnAuctionDebt, "Settlement/not-enough-ash");
        require(fxp45Int <= cdpCore.dai(address(this)), "Settlement/insufficient-surplus");
        totalOnAuctionDebt = sub(totalOnAuctionDebt, fxp45Int);
        cdpCore.settleDebtUsingSurplus(fxp45Int);
    }

    // Debt auction
    function startBadDebtAuction() external note returns (uint id) {
        require(debtAuctionLotSize <= sub(sub(cdpCore.badDebt(address(this)), totalDebtInDebtQueue), totalOnAuctionDebt), "Settlement/insufficient-debt");
        require(cdpCore.dai(address(this)) == 0, "Settlement/surplus-not-zero");
        totalOnAuctionDebt = add(totalOnAuctionDebt, debtAuctionLotSize);
        id = badDebtAuction.startAuction(address(this), dump, debtAuctionLotSize);
    }
    // Surplus auction
    function startSurplusAuction() external note returns (uint id) {
        require(cdpCore.dai(address(this)) >= add(add(cdpCore.badDebt(address(this)), surplusAuctionLotSize), surplusAuctionBuffer), "Settlement/insufficient-surplus");
        require(sub(sub(cdpCore.badDebt(address(this)), totalDebtInDebtQueue), totalOnAuctionDebt) == 0, "Settlement/debt-not-zero");
        id = surplusAuction.startAuction(surplusAuctionLotSize, 0);
    }

    function disable() external note isAuthorized {
        require(isAlive == 1, "Settlement/not-isAlive");
        isAlive = 0;
        totalDebtInDebtQueue = 0;
        totalOnAuctionDebt = 0;
        surplusAuction.disable(cdpCore.dai(address(surplusAuction)));
        badDebtAuction.disable();
        cdpCore.settleDebtUsingSurplus(min(cdpCore.dai(address(this)), cdpCore.badDebt(address(this))));
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

/// collateralForDaiAuction.sol -- Collateral auction

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
    function transfer(address,address,uint256) external;
    function transferCollateral(bytes32,address,address,uint256) external;
}

interface CatLike {
    function claw(uint256) external;
}

/*
   This thing lets you collateralForDaiAuction some collateralTokens for a given amount of dai.
   Once the given amount of dai is raised, collateralTokens are forgone instead.

 - `lot` collateralTokens in return for bid
 - `tab` total dai wanted
 - `bid` dai paid
 - `incomeRecipient` receives dai income
 - `usr` receives collateralToken forgone
 - `ttl` single bid lifetime
 - `minimumBidIncrease` minimum bid increase
 - `auctionEndTimestamp` max auction duration
*/

contract Flipper is LibNote {
    // --- Auth ---
    mapping (address => uint256) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "Flipper/not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        uint256 bid;  // dai paid                 [fxp45Int]
        uint256 lot;  // collateralTokens in return for bid   [fxp18Int]
        address highBidder;  // high bidder
        uint48  bidExpiry;  // bid expiry time          [unix epoch time]
        uint48  auctionEndTimestamp;  // auction expiry time      [unix epoch time]
        address usr;
        address incomeRecipient;
        uint256 tab;  // total dai wanted         [fxp45Int]
    }

    mapping (uint256 => Bid) public bids;

    CDPCoreInterface public   cdpCore;            // CDP Engine
    bytes32 public   collateralType;            // collateral type

    uint256 constant ONE = 1.00E18;
    uint256 public   minimumBidIncrease = 1.05E18;  // 5% minimum bid increase
    uint48  public   ttl = 3 hours;  // 3 hours bid duration         [seconds]
    uint48  public   maximumAuctionDuration = 2 days;   // 2 days total auction length  [seconds]
    uint256 public kicks = 0;
    CatLike public   cat;            // cat liquidation module

    // --- Events ---
    event StartAuction(
      uint256 id,
      uint256 lot,
      uint256 bid,
      uint256 tab,
      address indexed usr,
      address indexed incomeRecipient
    );

    // --- Init ---
    constructor(address core_, address cat_, bytes32 ilk_) public {
        cdpCore = CDPCoreInterface(core_);
        cat = CatLike(cat_);
        collateralType = ilk_;
        auths[msg.sender] = 1;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Admin ---
    function changeConfig(bytes32 what, uint256 data) external note isAuthorized {
        if (what == "minimumBidIncrease") minimumBidIncrease = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "maximumAuctionDuration") maximumAuctionDuration = uint48(data);
        else revert("Flipper/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, address data) external note isAuthorized {
        if (what == "cat") cat = CatLike(data);
        else revert("Flipper/changeConfig-unrecognized-param");
    }

    // --- Auction ---
    function startAuction(address usr, address incomeRecipient, uint256 tab, uint256 lot, uint256 bid)
        public isAuthorized returns (uint256 id)
    {
        require(kicks < uint256(-1), "Flipper/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].highBidder = msg.sender;  // configurable??
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
        bids[id].usr = usr;
        bids[id].incomeRecipient = incomeRecipient;
        bids[id].tab = tab;

        cdpCore.transferCollateral(collateralType, msg.sender, address(this), lot);

        emit StartAuction(id, lot, bid, tab, usr, incomeRecipient);
    }
    function restartAuction(uint256 id) external note {
        require(bids[id].auctionEndTimestamp < now, "Flipper/not-finished");
        require(bids[id].bidExpiry == 0, "Flipper/bid-already-placed");
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
    }
    function makeBidIncreaseBidSize(uint256 id, uint256 lot, uint256 bid) external note {
        require(bids[id].highBidder != address(0), "Flipper/highBidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "Flipper/already-finished-bidExpiry");
        require(bids[id].auctionEndTimestamp > now, "Flipper/already-finished-auctionEndTimestamp");

        require(lot == bids[id].lot, "Flipper/lot-not-matching");
        require(bid <= bids[id].tab, "Flipper/higher-than-tab");
        require(bid >  bids[id].bid, "Flipper/bid-not-higher");
        require(mul(bid, ONE) >= mul(minimumBidIncrease, bids[id].bid) || bid == bids[id].tab, "Flipper/insufficient-increase");

        if (msg.sender != bids[id].highBidder) {
            cdpCore.transfer(msg.sender, bids[id].highBidder, bids[id].bid);
            bids[id].highBidder = msg.sender;
        }
        cdpCore.transfer(msg.sender, bids[id].incomeRecipient, bid - bids[id].bid);

        bids[id].bid = bid;
        bids[id].bidExpiry = add(uint48(now), ttl);
    }
    function makeBidDecreaseLotSize(uint256 id, uint256 lot, uint256 bid) external note {
        require(bids[id].highBidder != address(0), "Flipper/highBidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "Flipper/already-finished-bidExpiry");
        require(bids[id].auctionEndTimestamp > now, "Flipper/already-finished-auctionEndTimestamp");

        require(bid == bids[id].bid, "Flipper/not-matching-bid");
        require(bid == bids[id].tab, "Flipper/makeBidIncreaseBidSize-not-finished");
        require(lot < bids[id].lot, "Flipper/lot-not-lower");
        require(mul(minimumBidIncrease, lot) <= mul(bids[id].lot, ONE), "Flipper/insufficient-decrease");

        if (msg.sender != bids[id].highBidder) {
            cdpCore.transfer(msg.sender, bids[id].highBidder, bid);
            bids[id].highBidder = msg.sender;
        }
        cdpCore.transferCollateral(collateralType, address(this), bids[id].usr, bids[id].lot - lot);

        bids[id].lot = lot;
        bids[id].bidExpiry = add(uint48(now), ttl);
    }
    function claimWinningBid(uint256 id) external note {
        require(bids[id].bidExpiry != 0 && (bids[id].bidExpiry < now || bids[id].auctionEndTimestamp < now), "Flipper/not-finished");
        cat.claw(bids[id].tab);
        cdpCore.transferCollateral(collateralType, address(this), bids[id].highBidder, bids[id].lot);
        delete bids[id];
    }

    function closeBid(uint256 id) external note isAuthorized {
        require(bids[id].highBidder != address(0), "Flipper/highBidder-not-set");
        require(bids[id].bid < bids[id].tab, "Flipper/already-makeBidDecreaseLotSize-phase");
        cat.claw(bids[id].tab);
        cdpCore.transferCollateral(collateralType, address(this), msg.sender, bids[id].lot);
        cdpCore.transfer(msg.sender, bids[id].highBidder, bids[id].bid);
        delete bids[id];
    }
}

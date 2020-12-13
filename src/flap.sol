// SPDX-License-Identifier: AGPL-3.0-or-later

/// flap.sol -- Surplus auction

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
    function transfer(address,address,uint) external;
}
interface CollateralTokensInterface {
    function transfer(address,address,uint) external;
    function burn(address,uint) external;
}

/*
   This thing lets you sell some dai in return for collateralTokens.

 - `lot` dai in return for bid
 - `bid` collateralTokens paid
 - `ttl` single bid lifetime
 - `minimumBidIncrease` minimum bid increase
 - `auctionEndTimestamp` max auction duration
*/

contract SurplusAuction is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "SurplusAuction/not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        uint256 bid;  // collateralTokens paid               [fxp18Int]
        uint256 lot;  // dai in return for bid   [fxp45Int]
        address highBidder;  // high bidder
        uint48  bidExpiry;  // bid expiry time         [unix epoch time]
        uint48  auctionEndTimestamp;  // auction expiry time     [unix epoch time]
    }

    mapping (uint => Bid) public bids;

    CDPCoreInterface  public   cdpCore;  // CDP Engine
    CollateralTokensInterface  public   collateralToken;

    uint256  constant ONE = 1.00E18;
    uint256  public   minimumBidIncrease = 1.05E18;  // 5% minimum bid increase
    uint48   public   ttl = 3 hours;  // 3 hours bid duration         [seconds]
    uint48   public   maximumAuctionDuration = 2 days;   // 2 days total auction length  [seconds]
    uint256  public kicks = 0;
    uint256  public isAlive;  // Active Flag

    // --- Events ---
    event StartAuction(
      uint256 id,
      uint256 lot,
      uint256 bid
    );

    // --- Init ---
    constructor(address core_, address collateralToken_) public {
        auths[msg.sender] = 1;
        cdpCore = CDPCoreInterface(core_);
        collateralToken = CollateralTokensInterface(collateralToken_);
        isAlive = 1;
    }

    // --- Math ---
    function add(uint48 x, uint48 y) internal pure returns (uint48 z) {
        require((z = x + y) >= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Admin ---
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        if (what == "minimumBidIncrease") minimumBidIncrease = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "maximumAuctionDuration") maximumAuctionDuration = uint48(data);
        else revert("SurplusAuction/changeConfig-unrecognized-param");
    }

    // --- Auction ---
    function startAuction(uint lot, uint bid) external isAuthorized returns (uint id) {
        require(isAlive == 1, "SurplusAuction/not-isAlive");
        require(kicks < uint(-1), "SurplusAuction/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].highBidder = msg.sender;  // configurable??
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);

        cdpCore.transfer(msg.sender, address(this), lot);

        emit StartAuction(id, lot, bid);
    }
    function restartAuction(uint id) external note {
        require(bids[id].auctionEndTimestamp < now, "SurplusAuction/not-finished");
        require(bids[id].bidExpiry == 0, "SurplusAuction/bid-already-placed");
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
    }
    function makeBidIncreaseBidSize(uint id, uint lot, uint bid) external note {
        require(isAlive == 1, "SurplusAuction/not-isAlive");
        require(bids[id].highBidder != address(0), "SurplusAuction/highBidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "SurplusAuction/already-finished-bidExpiry");
        require(bids[id].auctionEndTimestamp > now, "SurplusAuction/already-finished-auctionEndTimestamp");

        require(lot == bids[id].lot, "SurplusAuction/lot-not-matching");
        require(bid >  bids[id].bid, "SurplusAuction/bid-not-higher");
        require(mul(bid, ONE) >= mul(minimumBidIncrease, bids[id].bid), "SurplusAuction/insufficient-increase");

        if (msg.sender != bids[id].highBidder) {
            collateralToken.transfer(msg.sender, bids[id].highBidder, bids[id].bid);
            bids[id].highBidder = msg.sender;
        }
        collateralToken.transfer(msg.sender, address(this), bid - bids[id].bid);

        bids[id].bid = bid;
        bids[id].bidExpiry = add(uint48(now), ttl);
    }
    function claimWinningBid(uint id) external note {
        require(isAlive == 1, "SurplusAuction/not-isAlive");
        require(bids[id].bidExpiry != 0 && (bids[id].bidExpiry < now || bids[id].auctionEndTimestamp < now), "SurplusAuction/not-finished");
        cdpCore.transfer(address(this), bids[id].highBidder, bids[id].lot);
        collateralToken.burn(address(this), bids[id].bid);
        delete bids[id];
    }

    function disable(uint fxp45Int) external note isAuthorized {
       isAlive = 0;
       cdpCore.transfer(address(this), msg.sender, fxp45Int);
    }
    function closeBid(uint id) external note {
        require(isAlive == 0, "SurplusAuction/still-isAlive");
        require(bids[id].highBidder != address(0), "SurplusAuction/highBidder-not-set");
        collateralToken.transfer(address(this), bids[id].highBidder, bids[id].bid);
        delete bids[id];
    }
}

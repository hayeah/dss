// SPDX-License-Identifier: AGPL-3.0-or-later

/// flop.sol -- Debt auction

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
    function issueBadDebt(address,address,uint) external;
}
interface CollateralTokensInterface {
    function mint(address,uint) external;
}
interface SettlementInterface {
    function totalOnAuctionDebt() external returns (uint);
    function settleOnAuctionDebtUsingSurplus(uint) external;
}

/*
   This thing creates collateralTokens on demand in return for dai.

 - `lot` collateralTokens in return for bid
 - `bid` dai paid
 - `incomeRecipient` receives dai income
 - `ttl` single bid lifetime
 - `minimumBidIncrease` minimum bid increase
 - `auctionEndTimestamp` max auction duration
*/

contract BadDebtAuction is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "BadDebtAuction/not-authorized");
        _;
    }

    // --- Data ---
    struct Bid {
        uint256 bid;  // dai paid                [fxp45Int]
        uint256 lot;  // collateralTokens in return for bid  [fxp18Int]
        address highBidder;  // high bidder
        uint48  bidExpiry;  // bid expiry time         [unix epoch time]
        uint48  auctionEndTimestamp;  // auction expiry time     [unix epoch time]
    }

    mapping (uint => Bid) public bids;

    CDPCoreInterface  public   cdpCore;  // CDP Engine
    CollateralTokensInterface  public   collateralToken;

    uint256  constant ONE = 1.00E18;
    uint256  public   minimumBidIncrease = 1.05E18;  // 5% minimum bid increase
    uint256  public   pad = 1.50E18;  // 50% lot increase for restartAuction
    uint48   public   ttl = 3 hours;  // 3 hours bid lifetime         [seconds]
    uint48   public   maximumAuctionDuration = 2 days;   // 2 days total auction length  [seconds]
    uint256  public kicks = 0;
    uint256  public isAlive;             // Active Flag
    address  public settlement;              // not used until shutdown

    // --- Events ---
    event StartAuction(
      uint256 id,
      uint256 lot,
      uint256 bid,
      address indexed incomeRecipient
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
    function min(uint x, uint y) internal pure returns (uint z) {
        if (x > y) { z = y; } else { z = x; }
    }

    // --- Admin ---
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        if (what == "minimumBidIncrease") minimumBidIncrease = data;
        else if (what == "pad") pad = data;
        else if (what == "ttl") ttl = uint48(data);
        else if (what == "maximumAuctionDuration") maximumAuctionDuration = uint48(data);
        else revert("BadDebtAuction/changeConfig-unrecognized-param");
    }

    // --- Auction ---
    function startAuction(address incomeRecipient, uint lot, uint bid) external isAuthorized returns (uint id) {
        require(isAlive == 1, "BadDebtAuction/not-isAlive");
        require(kicks < uint(-1), "BadDebtAuction/overflow");
        id = ++kicks;

        bids[id].bid = bid;
        bids[id].lot = lot;
        bids[id].highBidder = incomeRecipient;
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);

        emit StartAuction(id, lot, bid, incomeRecipient);
    }
    function restartAuction(uint id) external note {
        require(bids[id].auctionEndTimestamp < now, "BadDebtAuction/not-finished");
        require(bids[id].bidExpiry == 0, "BadDebtAuction/bid-already-placed");
        bids[id].lot = mul(pad, bids[id].lot) / ONE;
        bids[id].auctionEndTimestamp = add(uint48(now), maximumAuctionDuration);
    }
    function makeBidDecreaseLotSize(uint id, uint lot, uint bid) external note {
        require(isAlive == 1, "BadDebtAuction/not-isAlive");
        require(bids[id].highBidder != address(0), "BadDebtAuction/highBidder-not-set");
        require(bids[id].bidExpiry > now || bids[id].bidExpiry == 0, "BadDebtAuction/already-finished-bidExpiry");
        require(bids[id].auctionEndTimestamp > now, "BadDebtAuction/already-finished-auctionEndTimestamp");

        require(bid == bids[id].bid, "BadDebtAuction/not-matching-bid");
        require(lot <  bids[id].lot, "BadDebtAuction/lot-not-lower");
        require(mul(minimumBidIncrease, lot) <= mul(bids[id].lot, ONE), "BadDebtAuction/insufficient-decrease");

        if (msg.sender != bids[id].highBidder) {
            cdpCore.transfer(msg.sender, bids[id].highBidder, bid);

            // on first makeBidDecreaseLotSize, clear as much totalOnAuctionDebt as possible
            if (bids[id].bidExpiry == 0) {
                uint totalOnAuctionDebt = SettlementInterface(bids[id].highBidder).totalOnAuctionDebt();
                SettlementInterface(bids[id].highBidder).settleOnAuctionDebtUsingSurplus(min(bid, totalOnAuctionDebt));
            }

            bids[id].highBidder = msg.sender;
        }

        bids[id].lot = lot;
        bids[id].bidExpiry = add(uint48(now), ttl);
    }
    function claimWinningBid(uint id) external note {
        require(isAlive == 1, "BadDebtAuction/not-isAlive");
        require(bids[id].bidExpiry != 0 && (bids[id].bidExpiry < now || bids[id].auctionEndTimestamp < now), "BadDebtAuction/not-finished");
        collateralToken.mint(bids[id].highBidder, bids[id].lot);
        delete bids[id];
    }

    // --- Shutdown ---
    function disable() external note isAuthorized {
       isAlive = 0;
       settlement = msg.sender;
    }
    function closeBid(uint id) external note {
        require(isAlive == 0, "BadDebtAuction/still-isAlive");
        require(bids[id].highBidder != address(0), "BadDebtAuction/highBidder-not-set");
        cdpCore.issueBadDebt(settlement, bids[id].highBidder, bids[id].bid);
        delete bids[id];
    }
}

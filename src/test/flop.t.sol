pragma solidity >=0.5.12;

import {DSTest}  from "ds-test/test.sol";
import {DSToken} from "ds-token/token.sol";
import "../flop.sol";
import "../cdpCore.sol";


interface Hevm {
    function warp(uint256) external;
}

contract Guy {
    BadDebtAuction flop;
    constructor(BadDebtAuction flop_) public {
        flop = flop_;
        CDPCore(address(flop.cdpCore())).grantAccess(address(flop));
        DSToken(address(flop.collateralToken())).approve(address(flop));
    }
    function makeBidDecreaseLotSize(uint id, uint lot, uint bid) public {
        flop.makeBidDecreaseLotSize(id, lot, bid);
    }
    function claimWinningBid(uint id) public {
        flop.claimWinningBid(id);
    }
    function try_dent(uint id, uint lot, uint bid)
        public returns (bool ok)
    {
        string memory sig = "makeBidDecreaseLotSize(uint256,uint256,uint256)";
        (ok,) = address(flop).call(abi.encodeWithSignature(sig, id, lot, bid));
    }
    function try_deal(uint id)
        public returns (bool ok)
    {
        string memory sig = "claimWinningBid(uint256)";
        (ok,) = address(flop).call(abi.encodeWithSignature(sig, id));
    }
    function try_tick(uint id)
        public returns (bool ok)
    {
        string memory sig = "restartAuction(uint256)";
        (ok,) = address(flop).call(abi.encodeWithSignature(sig, id));
    }
}

contract Gal {
    uint public totalOnAuctionDebt;
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function startAuction(BadDebtAuction flop, uint lot, uint bid) external returns (uint) {
        totalOnAuctionDebt += bid;
        return flop.startAuction(address(this), lot, bid);
    }
    function settleOnAuctionDebtUsingSurplus(uint fxp45Int) external {
        totalOnAuctionDebt = sub(totalOnAuctionDebt, fxp45Int);
    }
    function disable(BadDebtAuction flop) external {
        flop.disable();
    }
}

contract Vatish is DSToken('') {
    uint constant ONE = 10 ** 27;
    function grantAccess(address usr) public {
         approve(usr, uint(-1));
    }
    function dai(address usr) public view returns (uint) {
         return balanceOf[usr];
    }
}

contract FlopTest is DSTest {
    Hevm hevm;

    BadDebtAuction flop;
    CDPCore     cdpCore;
    DSToken collateralToken;

    address ali;
    address bob;
    address incomeRecipient;

    function settleOnAuctionDebtUsingSurplus(uint) public pure { }  // arbitrary callback

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new CDPCore();
        collateralToken = new DSToken('');

        flop = new BadDebtAuction(address(cdpCore), address(collateralToken));

        ali = address(new Guy(flop));
        bob = address(new Guy(flop));
        incomeRecipient = address(new Gal());

        flop.authorizeAddress(incomeRecipient);
        flop.deauthorizeAddress(address(this));

        cdpCore.grantAccess(address(flop));
        cdpCore.authorizeAddress(address(flop));
        collateralToken.approve(address(flop));

        cdpCore.issueBadDebt(address(this), address(this), 1000 ether);

        cdpCore.transfer(address(this), ali, 200 ether);
        cdpCore.transfer(address(this), bob, 200 ether);
    }

    function test_kick() public {
        assertEq(cdpCore.dai(incomeRecipient), 0);
        assertEq(collateralToken.balanceOf(incomeRecipient), 0 ether);
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 5000 ether);
        // no value transferred
        assertEq(cdpCore.dai(incomeRecipient), 0);
        assertEq(collateralToken.balanceOf(incomeRecipient), 0 ether);
        // auction created with appropriate values
        assertEq(flop.kicks(), id);
        (uint256 bid, uint256 lot, address highBidder, uint48 bidExpiry, uint48 auctionEndTimestamp) = flop.bids(id);
        assertEq(bid, 5000 ether);
        assertEq(lot, 200 ether);
        assertTrue(highBidder == incomeRecipient);
        assertEq(uint256(bidExpiry), 0);
        assertEq(uint256(auctionEndTimestamp), now + flop.maximumAuctionDuration());
    }

    function test_dent() public {
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);

        Guy(ali).makeBidDecreaseLotSize(id, 100 ether, 10 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai(ali), 190 ether);
        // incomeRecipient receives payment
        assertEq(cdpCore.dai(incomeRecipient),  10 ether);
        assertEq(Gal(incomeRecipient).totalOnAuctionDebt(), 0 ether);

        Guy(bob).makeBidDecreaseLotSize(id, 80 ether, 10 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai(bob), 190 ether);
        // prev bidder refunded
        assertEq(cdpCore.dai(ali), 200 ether);
        // incomeRecipient receives no more
        assertEq(cdpCore.dai(incomeRecipient), 10 ether);

        hevm.warp(now + 5 weeks);
        assertEq(collateralToken.totalSupply(),  0 ether);
        collateralToken.setOwner(address(flop));
        Guy(bob).claimWinningBid(id);
        // collateralTokens minted on demand
        assertEq(collateralToken.totalSupply(), 80 ether);
        // bob gets the winnings
        assertEq(collateralToken.balanceOf(bob), 80 ether);
    }

    function test_dent_Ash_less_than_bid() public {
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);
        assertEq(cdpCore.dai(incomeRecipient),  0 ether);

        Gal(incomeRecipient).settleOnAuctionDebtUsingSurplus(1 ether);
        assertEq(Gal(incomeRecipient).totalOnAuctionDebt(), 9 ether);

        Guy(ali).makeBidDecreaseLotSize(id, 100 ether, 10 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai(ali), 190 ether);
        // incomeRecipient receives payment
        assertEq(cdpCore.dai(incomeRecipient),   10 ether);
        assertEq(Gal(incomeRecipient).totalOnAuctionDebt(), 0 ether);

        Guy(bob).makeBidDecreaseLotSize(id, 80 ether, 10 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai(bob), 190 ether);
        // prev bidder refunded
        assertEq(cdpCore.dai(ali), 200 ether);
        // incomeRecipient receives no more
        assertEq(cdpCore.dai(incomeRecipient), 10 ether);

        hevm.warp(now + 5 weeks);
        assertEq(collateralToken.totalSupply(),  0 ether);
        collateralToken.setOwner(address(flop));
        Guy(bob).claimWinningBid(id);
        // collateralTokens minted on demand
        assertEq(collateralToken.totalSupply(), 80 ether);
        // bob gets the winnings
        assertEq(collateralToken.balanceOf(bob), 80 ether);
    }

    function test_dent_same_bidder() public {
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 200 ether);

        Guy(ali).makeBidDecreaseLotSize(id, 100 ether, 200 ether);
        assertEq(cdpCore.dai(ali), 0);
        Guy(ali).makeBidDecreaseLotSize(id, 50 ether, 200 ether);
    }

    function test_tick() public {
        // start an auction
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);
        // check no restartAuction
        assertTrue(!Guy(ali).try_tick(id));
        // run past the auctionEndTimestamp
        hevm.warp(now + 2 weeks);
        // check not biddable
        assertTrue(!Guy(ali).try_dent(id, 100 ether, 10 ether));
        assertTrue( Guy(ali).try_tick(id));
        // check biddable
        (, uint _lot,,,) = flop.bids(id);
        // restartAuction should increase the lot by pad (50%) and restart the auction
        assertEq(_lot, 300 ether);
        assertTrue( Guy(ali).try_dent(id, 100 ether, 10 ether));
    }

    function test_no_deal_after_end() public {
        // if there are no bids and the auction ends, then it should not
        // be refundable to the creator. Rather, it ticks indefinitely.
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);
        assertTrue(!Guy(ali).try_deal(id));
        hevm.warp(now + 2 weeks);
        assertTrue(!Guy(ali).try_deal(id));
        assertTrue( Guy(ali).try_tick(id));
        assertTrue(!Guy(ali).try_deal(id));
    }

    function test_yank() public {
        // yanking the auction should refund the last bidder's dai, credit a
        // corresponding amount of badDebt to the caller of disable, and delete the auction.
        // in practice, incomeRecipient == (caller of disable) == (settlement address)
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);

        // confrim initial state expectations
        assertEq(cdpCore.dai(ali), 200 ether);
        assertEq(cdpCore.dai(bob), 200 ether);
        assertEq(cdpCore.dai(incomeRecipient), 0);
        assertEq(cdpCore.badDebt(incomeRecipient), 0);

        Guy(ali).makeBidDecreaseLotSize(id, 100 ether, 10 ether);
        Guy(bob).makeBidDecreaseLotSize(id, 80 ether, 10 ether);

        // confirm the proper state updates have occurred
        assertEq(cdpCore.dai(ali), 200 ether);  // ali's dai balance is unchanged
        assertEq(cdpCore.dai(bob), 190 ether);
        assertEq(cdpCore.dai(incomeRecipient),  10 ether);
        assertEq(cdpCore.badDebt(address(this)), 1000 ether);

        Gal(incomeRecipient).disable(flop);
        flop.closeBid(id);

        // confirm final state
        assertEq(cdpCore.dai(ali), 200 ether);
        assertEq(cdpCore.dai(bob), 200 ether);  // bob's bid has been refunded
        assertEq(cdpCore.dai(incomeRecipient),  10 ether);
        assertEq(cdpCore.badDebt(incomeRecipient),  10 ether);  // badDebt assigned to caller of disable()
        (uint256 _bid, uint256 _lot, address _guy, uint48 _tic, uint48 _end) = flop.bids(id);
        assertEq(_bid, 0);
        assertEq(_lot, 0);
        assertEq(_guy, address(0));
        assertEq(uint256(_tic), 0);
        assertEq(uint256(_end), 0);
    }

    function test_yank_no_bids() public {
        // with no bidder to refund, yanking the auction should simply create equal
        // amounts of dai (credited to the incomeRecipient) and badDebt (credited to the caller of disable)
        // in practice, incomeRecipient == (caller of disable) == (settlement address)
        uint id = Gal(incomeRecipient).startAuction(flop, /*lot*/ 200 ether, /*bid*/ 10 ether);

        // confrim initial state expectations
        assertEq(cdpCore.dai(ali), 200 ether);
        assertEq(cdpCore.dai(bob), 200 ether);
        assertEq(cdpCore.dai(incomeRecipient), 0);
        assertEq(cdpCore.badDebt(incomeRecipient), 0);

        Gal(incomeRecipient).disable(flop);
        flop.closeBid(id);

        // confirm final state
        assertEq(cdpCore.dai(ali), 200 ether);
        assertEq(cdpCore.dai(bob), 200 ether);
        assertEq(cdpCore.dai(incomeRecipient),  10 ether);
        assertEq(cdpCore.badDebt(incomeRecipient),  10 ether);  // badDebt assigned to caller of disable()
        (uint256 _bid, uint256 _lot, address _guy, uint48 _tic, uint48 _end) = flop.bids(id);
        assertEq(_bid, 0);
        assertEq(_lot, 0);
        assertEq(_guy, address(0));
        assertEq(uint256(_tic), 0);
        assertEq(uint256(_end), 0);
    }
}

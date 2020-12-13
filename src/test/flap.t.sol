pragma solidity >=0.5.12;

import "ds-test/test.sol";
import {DSToken} from "ds-token/token.sol";
import "../flap.sol";
import "../cdpCore.sol";


interface Hevm {
    function warp(uint256) external;
}

contract Guy {
    SurplusAuction flap;
    constructor(SurplusAuction flap_) public {
        flap = flap_;
        CDPCore(address(flap.cdpCore())).grantAccess(address(flap));
        DSToken(address(flap.collateralToken())).approve(address(flap));
    }
    function makeBidIncreaseBidSize(uint id, uint lot, uint bid) public {
        flap.makeBidIncreaseBidSize(id, lot, bid);
    }
    function claimWinningBid(uint id) public {
        flap.claimWinningBid(id);
    }
    function try_tend(uint id, uint lot, uint bid)
        public returns (bool ok)
    {
        string memory sig = "makeBidIncreaseBidSize(uint256,uint256,uint256)";
        (ok,) = address(flap).call(abi.encodeWithSignature(sig, id, lot, bid));
    }
    function try_deal(uint id)
        public returns (bool ok)
    {
        string memory sig = "claimWinningBid(uint256)";
        (ok,) = address(flap).call(abi.encodeWithSignature(sig, id));
    }
    function try_tick(uint id)
        public returns (bool ok)
    {
        string memory sig = "restartAuction(uint256)";
        (ok,) = address(flap).call(abi.encodeWithSignature(sig, id));
    }
}

contract FlapTest is DSTest {
    Hevm hevm;

    SurplusAuction flap;
    CDPCore     cdpCore;
    DSToken collateralToken;

    address ali;
    address bob;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new CDPCore();
        collateralToken = new DSToken('');

        flap = new SurplusAuction(address(cdpCore), address(collateralToken));

        ali = address(new Guy(flap));
        bob = address(new Guy(flap));

        cdpCore.grantAccess(address(flap));
        collateralToken.approve(address(flap));

        cdpCore.issueBadDebt(address(this), address(this), 1000 ether);

        collateralToken.mint(1000 ether);
        collateralToken.setOwner(address(flap));

        collateralToken.push(ali, 200 ether);
        collateralToken.push(bob, 200 ether);
    }
    function test_kick() public {
        assertEq(cdpCore.dai(address(this)), 1000 ether);
        assertEq(cdpCore.dai(address(flap)),    0 ether);
        flap.startAuction({ lot: 100 ether
                  , bid: 0
                  });
        assertEq(cdpCore.dai(address(this)),  900 ether);
        assertEq(cdpCore.dai(address(flap)),  100 ether);
    }
    function test_tend() public {
        uint id = flap.startAuction({ lot: 100 ether
                            , bid: 0
                            });
        // lot taken from creator
        assertEq(cdpCore.dai(address(this)), 900 ether);

        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 1 ether);
        // bid taken from bidder
        assertEq(collateralToken.balanceOf(ali), 199 ether);
        // payment remains in auction
        assertEq(collateralToken.balanceOf(address(flap)),  1 ether);

        Guy(bob).makeBidIncreaseBidSize(id, 100 ether, 2 ether);
        // bid taken from bidder
        assertEq(collateralToken.balanceOf(bob), 198 ether);
        // prev bidder refunded
        assertEq(collateralToken.balanceOf(ali), 200 ether);
        // excess remains in auction
        assertEq(collateralToken.balanceOf(address(flap)),   2 ether);

        hevm.warp(now + 5 weeks);
        Guy(bob).claimWinningBid(id);
        // high bidder gets the lot
        assertEq(cdpCore.dai(address(flap)),  0 ether);
        assertEq(cdpCore.dai(bob), 100 ether);
        // income is burned
        assertEq(collateralToken.balanceOf(address(flap)),   0 ether);
    }
    function test_tend_same_bidder() public {
        uint id = flap.startAuction({ lot: 100 ether
                            , bid: 0
                            });
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 190 ether);
        assertEq(collateralToken.balanceOf(ali), 10 ether);
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 200 ether);
        assertEq(collateralToken.balanceOf(ali), 0);
    }
    function test_beg() public {
        uint id = flap.startAuction({ lot: 100 ether
                            , bid: 0
                            });
        assertTrue( Guy(ali).try_tend(id, 100 ether, 1.00 ether));
        assertTrue(!Guy(bob).try_tend(id, 100 ether, 1.01 ether));
        // high bidder is subject to minimumBidIncrease
        assertTrue(!Guy(ali).try_tend(id, 100 ether, 1.01 ether));
        assertTrue( Guy(bob).try_tend(id, 100 ether, 1.07 ether));
    }
    function test_tick() public {
        // start an auction
        uint id = flap.startAuction({ lot: 100 ether
                            , bid: 0
                            });
        // check no restartAuction
        assertTrue(!Guy(ali).try_tick(id));
        // run past the auctionEndTimestamp
        hevm.warp(now + 2 weeks);
        // check not biddable
        assertTrue(!Guy(ali).try_tend(id, 100 ether, 1 ether));
        assertTrue( Guy(ali).try_tick(id));
        // check biddable
        assertTrue( Guy(ali).try_tend(id, 100 ether, 1 ether));
    }
}

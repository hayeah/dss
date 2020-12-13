pragma solidity >=0.5.12;

import "ds-test/test.sol";

import {CDPCore}     from "../cdpCore.sol";
import {Liquidation}     from "../cat.sol";
import {Flipper} from "../collateralForDaiAuction.sol";

interface Hevm {
    function warp(uint256) external;
}

contract Guy {
    Flipper collateralForDaiAuction;
    constructor(Flipper flip_) public {
        collateralForDaiAuction = flip_;
    }
    function grantAccess(address usr) public {
        CDPCore(address(collateralForDaiAuction.cdpCore())).grantAccess(usr);
    }
    function makeBidIncreaseBidSize(uint id, uint lot, uint bid) public {
        collateralForDaiAuction.makeBidIncreaseBidSize(id, lot, bid);
    }
    function makeBidDecreaseLotSize(uint id, uint lot, uint bid) public {
        collateralForDaiAuction.makeBidDecreaseLotSize(id, lot, bid);
    }
    function claimWinningBid(uint id) public {
        collateralForDaiAuction.claimWinningBid(id);
    }
    function try_tend(uint id, uint lot, uint bid)
        public returns (bool ok)
    {
        string memory sig = "makeBidIncreaseBidSize(uint256,uint256,uint256)";
        (ok,) = address(collateralForDaiAuction).call(abi.encodeWithSignature(sig, id, lot, bid));
    }
    function try_dent(uint id, uint lot, uint bid)
        public returns (bool ok)
    {
        string memory sig = "makeBidDecreaseLotSize(uint256,uint256,uint256)";
        (ok,) = address(collateralForDaiAuction).call(abi.encodeWithSignature(sig, id, lot, bid));
    }
    function try_deal(uint id)
        public returns (bool ok)
    {
        string memory sig = "claimWinningBid(uint256)";
        (ok,) = address(collateralForDaiAuction).call(abi.encodeWithSignature(sig, id));
    }
    function try_tick(uint id)
        public returns (bool ok)
    {
        string memory sig = "restartAuction(uint256)";
        (ok,) = address(collateralForDaiAuction).call(abi.encodeWithSignature(sig, id));
    }
    function try_yank(uint id)
        public returns (bool ok)
    {
        string memory sig = "closeBid(uint256)";
        (ok,) = address(collateralForDaiAuction).call(abi.encodeWithSignature(sig, id));
    }
}


contract Gal {}

contract Cat_ is Liquidation {
    uint256 constant public RAD = 10 ** 45;
    uint256 constant public MLN = 10 **  6;

    constructor(address core_) Liquidation(core_) public {
        litter = 5 * MLN * RAD;
    }
}

contract Vat_ is CDPCore {
    function mint(address usr, uint fxp18Int) public {
        dai[usr] += fxp18Int;
    }
    function dai_balance(address usr) public view returns (uint) {
        return dai[usr];
    }
    bytes32 collateralType;
    function set_ilk(bytes32 ilk_) public {
        collateralType = ilk_;
    }
    function gem_balance(address usr) public view returns (uint) {
        return collateralToken[collateralType][usr];
    }
}

contract FlipTest is DSTest {
    Hevm hevm;

    Vat_    cdpCore;
    Cat_    cat;
    Flipper collateralForDaiAuction;

    address ali;
    address bob;
    address incomeRecipient;
    address usr = address(0xacab);

    uint256 constant public RAY = 10 ** 27;
    uint256 constant public RAD = 10 ** 45;
    uint256 constant public MLN = 10 **  6;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new Vat_();
        cat = new Cat_(address(cdpCore));

        cdpCore.createNewCollateralType("collateralTokens");
        cdpCore.set_ilk("collateralTokens");

        collateralForDaiAuction = new Flipper(address(cdpCore), address(cat), "collateralTokens");
        cat.authorizeAddress(address(collateralForDaiAuction));

        ali = address(new Guy(collateralForDaiAuction));
        bob = address(new Guy(collateralForDaiAuction));
        incomeRecipient = address(new Gal());

        Guy(ali).grantAccess(address(collateralForDaiAuction));
        Guy(bob).grantAccess(address(collateralForDaiAuction));
        cdpCore.grantAccess(address(collateralForDaiAuction));

        cdpCore.modifyUsersCollateralBalance("collateralTokens", address(this), 1000 ether);
        cdpCore.mint(ali, 200 ether);
        cdpCore.mint(bob, 200 ether);
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }
    function test_kick() public {
        collateralForDaiAuction.startAuction({ lot: 100 ether
                  , tab: 50 ether
                  , usr: usr
                  , incomeRecipient: incomeRecipient
                  , bid: 0
                  });
    }
    function testFail_tend_empty() public {
        // can't makeBidIncreaseBidSize on non-existent
        collateralForDaiAuction.makeBidIncreaseBidSize(42, 0, 0);
    }
    function test_tend() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 1 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai_balance(ali),   199 ether);
        // incomeRecipient receives payment
        assertEq(cdpCore.dai_balance(incomeRecipient),     1 ether);

        Guy(bob).makeBidIncreaseBidSize(id, 100 ether, 2 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai_balance(bob), 198 ether);
        // prev bidder refunded
        assertEq(cdpCore.dai_balance(ali), 200 ether);
        // incomeRecipient receives excess
        assertEq(cdpCore.dai_balance(incomeRecipient),   2 ether);

        hevm.warp(now + 5 hours);
        Guy(bob).claimWinningBid(id);
        // bob gets the winnings
        assertEq(cdpCore.gem_balance(bob), 100 ether);
    }
    function test_tend_later() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });
        hevm.warp(now + 5 hours);

        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 1 ether);
        // bid taken from bidder
        assertEq(cdpCore.dai_balance(ali), 199 ether);
        // incomeRecipient receives payment
        assertEq(cdpCore.dai_balance(incomeRecipient),   1 ether);
    }
    function test_dent() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether,  1 ether);
        Guy(bob).makeBidIncreaseBidSize(id, 100 ether, 50 ether);

        Guy(ali).makeBidDecreaseLotSize(id,  95 ether, 50 ether);
        // plop the collateralTokens
        assertEq(cdpCore.gem_balance(address(0xacab)), 5 ether);
        assertEq(cdpCore.dai_balance(ali),  150 ether);
        assertEq(cdpCore.dai_balance(bob),  200 ether);
    }
    function test_tend_dent_same_bidder() public {
       uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 200 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        assertEq(cdpCore.dai_balance(ali), 200 ether);
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 190 ether);
        assertEq(cdpCore.dai_balance(ali), 10 ether);
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 200 ether);
        assertEq(cdpCore.dai_balance(ali), 0);
        Guy(ali).makeBidDecreaseLotSize(id, 80 ether, 200 ether);
    }
    function test_beg() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });
        assertTrue( Guy(ali).try_tend(id, 100 ether, 1.00 ether));
        assertTrue(!Guy(bob).try_tend(id, 100 ether, 1.01 ether));
        // high bidder is subject to minimumBidIncrease
        assertTrue(!Guy(ali).try_tend(id, 100 ether, 1.01 ether));
        assertTrue( Guy(bob).try_tend(id, 100 ether, 1.07 ether));

        // can bid by less than minimumBidIncrease at collateralForDaiAuction
        assertTrue( Guy(ali).try_tend(id, 100 ether, 49 ether));
        assertTrue( Guy(bob).try_tend(id, 100 ether, 50 ether));

        assertTrue(!Guy(ali).try_dent(id, 100 ether, 50 ether));
        assertTrue(!Guy(ali).try_dent(id,  99 ether, 50 ether));
        assertTrue( Guy(ali).try_dent(id,  95 ether, 50 ether));
    }
    function test_deal() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        // only after ttl
        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 1 ether);
        assertTrue(!Guy(bob).try_deal(id));
        hevm.warp(now + 4.1 hours);
        assertTrue( Guy(bob).try_deal(id));

        uint ie = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        // or after auctionEndTimestamp
        hevm.warp(now + 44 hours);
        Guy(ali).makeBidIncreaseBidSize(ie, 100 ether, 1 ether);
        assertTrue(!Guy(bob).try_deal(ie));
        hevm.warp(now + 1 days);
        assertTrue( Guy(bob).try_deal(ie));
    }
    function test_tick() public {
        // start an auction
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
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
    function test_no_deal_after_end() public {
        // if there are no bids and the auction ends, then it should not
        // be refundable to the creator. Rather, it ticks indefinitely.
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });
        assertTrue(!Guy(ali).try_deal(id));
        hevm.warp(now + 2 weeks);
        assertTrue(!Guy(ali).try_deal(id));
        assertTrue( Guy(ali).try_tick(id));
        assertTrue(!Guy(ali).try_deal(id));
    }
    function test_yank_tend() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: fxp45Int(50 ether)
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        Guy(ali).makeBidIncreaseBidSize(id, 100 ether, 1 ether);

        // bid taken from bidder
        assertEq(cdpCore.dai_balance(ali), 199 ether);
        assertEq(cdpCore.dai_balance(incomeRecipient),   1 ether);

        // we have some amount of litter in the box
        assertEq(cat.litter(), 5 * MLN * RAD);

        cdpCore.mint(address(this), 1 ether);
        collateralForDaiAuction.closeBid(id);

        // bid is refunded to bidder from caller
        assertEq(cdpCore.dai_balance(ali),            200 ether);
        assertEq(cdpCore.dai_balance(address(this)),    0 ether);

        // collateralTokens go to caller
        assertEq(cdpCore.gem_balance(address(this)), 1000 ether);

        // cat.scoop(tab) is called decrementing the litter accumulator
        assertEq(cat.litter(), (5 * MLN * RAD) - fxp45Int(50 ether));
    }
    function test_yank_dent() public {
        uint id = collateralForDaiAuction.startAuction({ lot: 100 ether
                            , tab: 50 ether
                            , usr: usr
                            , incomeRecipient: incomeRecipient
                            , bid: 0
                            });

        // we have some amount of litter in the box
        assertEq(cat.litter(), 5 * MLN * RAD);

        Guy(ali).makeBidIncreaseBidSize(id, 100 ether,  1 ether);
        Guy(bob).makeBidIncreaseBidSize(id, 100 ether, 50 ether);
        Guy(ali).makeBidDecreaseLotSize(id,  95 ether, 50 ether);

        // cannot closeBid in the makeBidDecreaseLotSize phase
        assertTrue(!Guy(ali).try_yank(id));

        // we have same amount of litter in the box
        assertEq(cat.litter(), 5 * MLN * RAD);
    }
}

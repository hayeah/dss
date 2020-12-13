pragma solidity >=0.5.12;

import "ds-test/test.sol";
import "ds-token/token.sol";

import {CDPCore} from '../cdpCore.sol';
import {Liquidation} from '../cat.sol';
import {Settlement} from '../settlement.sol';
import {Jug} from '../stabilityFeeDatabase.sol';
import {GemJoin, DaiJoin} from '../deposit.sol';

import {Flipper} from './collateralForDaiAuction.t.sol';
import {BadDebtAuction} from './flop.t.sol';
import {SurplusAuction} from './flap.t.sol';


interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestVat is CDPCore {
    uint256 constant ONE = 10 ** 27;
    function mint(address usr, uint fxp18Int) public {
        dai[usr] += fxp18Int * ONE;
        debt += fxp18Int * ONE;
    }
}

contract TestVow is Settlement {
    constructor(address cdpCore, address surplusAuction, address badDebtAuction)
        public Settlement(cdpCore, surplusAuction, badDebtAuction) {}
    // Total deficit
    function totalDebt() public view returns (uint) {
        return cdpCore.badDebt(address(this));
    }
    // Total surplus
    function totalSurplus() public view returns (uint) {
        return cdpCore.dai(address(this));
    }
    // Unqueued, pre-auction debt
    function totalNonQueuedNonAuctionDebt() public view returns (uint) {
        return sub(sub(totalDebt(), totalDebtInDebtQueue), totalOnAuctionDebt);
    }
}

contract Usr {
    CDPCore public cdpCore;
    constructor(CDPCore core_) public {
        cdpCore = core_;
    }
    function try_call(address highBidder, bytes calldata data) external returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas(), highBidder, 0, add(_data, 0x20), mload(_data), 0, 0)
            let transferCollateralFromCDP := mload(0x40)
            mstore(transferCollateralFromCDP, ok)
            mstore(0x40, add(transferCollateralFromCDP, 32))
            revert(transferCollateralFromCDP, 32)
        }
    }
    function can_frob(bytes32 collateralType, address u, address v, address w, int changeInCollateral, int changeInDebt) public returns (bool) {
        string memory sig = "modifyCDP(bytes32,address,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(sig, collateralType, u, v, w, changeInCollateral, changeInDebt);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", cdpCore, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function can_fork(bytes32 collateralType, address src, address dst, int changeInCollateral, int changeInDebt) public returns (bool) {
        string memory sig = "transferCDP(bytes32,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(sig, collateralType, src, dst, changeInCollateral, changeInDebt);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", cdpCore, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function modifyCDP(bytes32 collateralType, address u, address v, address w, int changeInCollateral, int changeInDebt) public {
        cdpCore.modifyCDP(collateralType, u, v, w, changeInCollateral, changeInDebt);
    }
    function transferCDP(bytes32 collateralType, address src, address dst, int changeInCollateral, int changeInDebt) public {
        cdpCore.transferCDP(collateralType, src, dst, changeInCollateral, changeInDebt);
    }
    function grantAccess(address usr) public {
        cdpCore.grantAccess(usr);
    }
}


contract FrobTest is DSTest {
    TestVat cdpCore;
    DSToken gold;
    Jug     stabilityFeeDatabase;

    GemJoin gemA;
    address me;

    function try_frob(bytes32 collateralType, int collateralBalance, int stablecoinDebt) public returns (bool ok) {
        string memory sig = "modifyCDP(bytes32,address,address,address,int256,int256)";
        address self = address(this);
        (ok,) = address(cdpCore).call(abi.encodeWithSignature(sig, collateralType, self, self, self, collateralBalance, stablecoinDebt));
    }

    function fxp27Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 9;
    }

    function setUp() public {
        cdpCore = new TestVat();

        gold = new DSToken("GEM");
        gold.mint(1000 ether);

        cdpCore.createNewCollateralType("gold");
        gemA = new GemJoin(address(cdpCore), "gold", address(gold));

        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral",    fxp27Int(1 ether));
        cdpCore.changeConfig("gold", "debtCeiling", fxp45Int(1000 ether));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(1000 ether));
        stabilityFeeDatabase = new Jug(address(cdpCore));
        stabilityFeeDatabase.createNewCollateralType("gold");
        cdpCore.authorizeAddress(address(stabilityFeeDatabase));

        gold.approve(address(gemA));
        gold.approve(address(cdpCore));

        cdpCore.authorizeAddress(address(cdpCore));
        cdpCore.authorizeAddress(address(gemA));

        gemA.deposit(address(this), 1000 ether);

        me = address(this);
    }

    function collateralToken(bytes32 collateralType, address cdp) internal view returns (uint) {
        return cdpCore.collateralToken(collateralType, cdp);
    }
    function collateralBalance(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); art_;
        return ink_;
    }
    function stablecoinDebt(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); ink_;
        return art_;
    }

    function test_setup() public {
        assertEq(gold.balanceOf(address(gemA)), 1000 ether);
        assertEq(collateralToken("gold",    address(this)), 1000 ether);
    }
    function test_join() public {
        address cdp = address(this);
        gold.mint(500 ether);
        assertEq(gold.balanceOf(address(this)),    500 ether);
        assertEq(gold.balanceOf(address(gemA)),   1000 ether);
        gemA.deposit(cdp,                             500 ether);
        assertEq(gold.balanceOf(address(this)),      0 ether);
        assertEq(gold.balanceOf(address(gemA)),   1500 ether);
        gemA.exit(cdp,                             250 ether);
        assertEq(gold.balanceOf(address(this)),    250 ether);
        assertEq(gold.balanceOf(address(gemA)),   1250 ether);
    }
    function test_lock() public {
        assertEq(collateralBalance("gold", address(this)),    0 ether);
        assertEq(collateralToken("gold", address(this)), 1000 ether);
        cdpCore.modifyCDP("gold", me, me, me, 6 ether, 0);
        assertEq(collateralBalance("gold", address(this)),   6 ether);
        assertEq(collateralToken("gold", address(this)), 994 ether);
        cdpCore.modifyCDP("gold", me, me, me, -6 ether, 0);
        assertEq(collateralBalance("gold", address(this)),    0 ether);
        assertEq(collateralToken("gold", address(this)), 1000 ether);
    }
    function test_calm() public {
        // isCdpBelowCollateralAndTotalDebtCeilings means that the debt ceiling is not exceeded
        // it's ok to increase debt as long as you remain isCdpBelowCollateralAndTotalDebtCeilings
        cdpCore.changeConfig("gold", 'debtCeiling', fxp45Int(10 ether));
        assertTrue( try_frob("gold", 10 ether, 9 ether));
        // only if under debt ceiling
        assertTrue(!try_frob("gold",  0 ether, 2 ether));
    }
    function test_cool() public {
        // isCdpDaiDebtNonIncreasing means that the debt has decreased
        // it's ok to be over the debt ceiling as long as you're isCdpDaiDebtNonIncreasing
        cdpCore.changeConfig("gold", 'debtCeiling', fxp45Int(10 ether));
        assertTrue(try_frob("gold", 10 ether,  8 ether));
        cdpCore.changeConfig("gold", 'debtCeiling', fxp45Int(5 ether));
        // can decrease debt when over ceiling
        assertTrue(try_frob("gold",  0 ether, -1 ether));
    }
    function test_safe() public {
        // isCdpSafe means that the cdp is not risky
        // you can't modifyCDP a cdp into unsafe
        cdpCore.modifyCDP("gold", me, me, me, 10 ether, 5 ether);                // isCdpSafe increaseCDPDebt
        assertTrue(!try_frob("gold", 0 ether, 6 ether));  // unsafe increaseCDPDebt
    }
    function test_nice() public {
        // nice means that the collateral has increased or the debt has
        // decreased. remaining unsafe is ok as long as you're nice

        cdpCore.modifyCDP("gold", me, me, me, 10 ether, 10 ether);
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(0.5 ether));  // now unsafe

        // debt can't increase if unsafe
        assertTrue(!try_frob("gold",  0 ether,  1 ether));
        // debt can decrease
        assertTrue( try_frob("gold",  0 ether, -1 ether));
        // collateralBalance can't decrease
        assertTrue(!try_frob("gold", -1 ether,  0 ether));
        // collateralBalance can increase
        assertTrue( try_frob("gold",  1 ether,  0 ether));

        // cdp is still unsafe
        // collateralBalance can't decrease, even if debt decreases more
        assertTrue(!this.try_frob("gold", -2 ether, -4 ether));
        // debt can't increase, even if collateralBalance increases more
        assertTrue(!this.try_frob("gold",  5 ether,  1 ether));

        // collateralBalance can decrease if auctionEndTimestamp state is isCdpSafe
        assertTrue( this.try_frob("gold", -1 ether, -4 ether));
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(0.4 ether));  // now unsafe
        // debt can increase if auctionEndTimestamp state is isCdpSafe
        assertTrue( this.try_frob("gold",  5 ether, 1 ether));
    }

    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }
    function test_alt_callers() public {
        Usr ali = new Usr(cdpCore);
        Usr bob = new Usr(cdpCore);
        Usr che = new Usr(cdpCore);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        cdpCore.modifyUsersCollateralBalance("gold", a, int(fxp45Int(20 ether)));
        cdpCore.modifyUsersCollateralBalance("gold", b, int(fxp45Int(20 ether)));
        cdpCore.modifyUsersCollateralBalance("gold", c, int(fxp45Int(20 ether)));

        ali.modifyCDP("gold", a, a, a, 10 ether, 5 ether);

        // anyone can transferCollateralToCDP
        assertTrue( ali.can_frob("gold", a, a, a,  1 ether,  0 ether));
        assertTrue( bob.can_frob("gold", a, b, b,  1 ether,  0 ether));
        assertTrue( che.can_frob("gold", a, c, c,  1 ether,  0 ether));
        // but only with their own collateralTokens
        assertTrue(!ali.can_frob("gold", a, b, a,  1 ether,  0 ether));
        assertTrue(!bob.can_frob("gold", a, c, b,  1 ether,  0 ether));
        assertTrue(!che.can_frob("gold", a, a, c,  1 ether,  0 ether));

        // only the lad can transferCollateralFromCDP
        assertTrue( ali.can_frob("gold", a, a, a, -1 ether,  0 ether));
        assertTrue(!bob.can_frob("gold", a, b, b, -1 ether,  0 ether));
        assertTrue(!che.can_frob("gold", a, c, c, -1 ether,  0 ether));
        // the lad can transferCollateralFromCDP to anywhere
        assertTrue( ali.can_frob("gold", a, b, a, -1 ether,  0 ether));
        assertTrue( ali.can_frob("gold", a, c, a, -1 ether,  0 ether));

        // only the lad can increaseCDPDebt
        assertTrue( ali.can_frob("gold", a, a, a,  0 ether,  1 ether));
        assertTrue(!bob.can_frob("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_frob("gold", a, c, c,  0 ether,  1 ether));
        // the lad can increaseCDPDebt to anywhere
        assertTrue( ali.can_frob("gold", a, a, b,  0 ether,  1 ether));
        assertTrue( ali.can_frob("gold", a, a, c,  0 ether,  1 ether));

        cdpCore.mint(address(bob), 1 ether);
        cdpCore.mint(address(che), 1 ether);

        // anyone can decreaseCDPDebt
        assertTrue( ali.can_frob("gold", a, a, a,  0 ether, -1 ether));
        assertTrue( bob.can_frob("gold", a, b, b,  0 ether, -1 ether));
        assertTrue( che.can_frob("gold", a, c, c,  0 ether, -1 ether));
        // but only with their own dai
        assertTrue(!ali.can_frob("gold", a, a, b,  0 ether, -1 ether));
        assertTrue(!bob.can_frob("gold", a, b, c,  0 ether, -1 ether));
        assertTrue(!che.can_frob("gold", a, c, a,  0 ether, -1 ether));
    }

    function test_grantAccess() public {
        Usr ali = new Usr(cdpCore);
        Usr bob = new Usr(cdpCore);
        Usr che = new Usr(cdpCore);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        cdpCore.modifyUsersCollateralBalance("gold", a, int(fxp45Int(20 ether)));
        cdpCore.modifyUsersCollateralBalance("gold", b, int(fxp45Int(20 ether)));
        cdpCore.modifyUsersCollateralBalance("gold", c, int(fxp45Int(20 ether)));

        ali.modifyCDP("gold", a, a, a, 10 ether, 5 ether);

        // only owner can do risky actions
        assertTrue( ali.can_frob("gold", a, a, a,  0 ether,  1 ether));
        assertTrue(!bob.can_frob("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_frob("gold", a, c, c,  0 ether,  1 ether));

        ali.grantAccess(address(bob));

        // unless they hope another user
        assertTrue( ali.can_frob("gold", a, a, a,  0 ether,  1 ether));
        assertTrue( bob.can_frob("gold", a, b, b,  0 ether,  1 ether));
        assertTrue(!che.can_frob("gold", a, c, c,  0 ether,  1 ether));
    }

    function test_dust() public {
        assertTrue( try_frob("gold", 9 ether,  1 ether));
        cdpCore.changeConfig("gold", "dust", fxp45Int(5 ether));
        assertTrue(!try_frob("gold", 5 ether,  2 ether));
        assertTrue( try_frob("gold", 0 ether,  5 ether));
        assertTrue(!try_frob("gold", 0 ether, -5 ether));
        assertTrue( try_frob("gold", 0 ether, -6 ether));
    }
}

contract JoinTest is DSTest {
    TestVat cdpCore;
    DSToken collateralToken;
    GemJoin gemA;
    DaiJoin daiA;
    DSToken dai;
    address me;

    function setUp() public {
        cdpCore = new TestVat();
        cdpCore.createNewCollateralType("eth");

        collateralToken  = new DSToken("Gem");
        gemA = new GemJoin(address(cdpCore), "collateralToken", address(collateralToken));
        cdpCore.authorizeAddress(address(gemA));

        dai  = new DSToken("Dai");
        daiA = new DaiJoin(address(cdpCore), address(dai));
        cdpCore.authorizeAddress(address(daiA));
        dai.setOwner(address(daiA));

        me = address(this);
    }
    function try_cage(address a) public payable returns (bool ok) {
        string memory sig = "disable()";
        (ok,) = a.call(abi.encodeWithSignature(sig));
    }
    function try_join_gem(address usr, uint fxp18Int) public returns (bool ok) {
        string memory sig = "deposit(address,uint256)";
        (ok,) = address(gemA).call(abi.encodeWithSignature(sig, usr, fxp18Int));
    }
    function try_exit_dai(address usr, uint fxp18Int) public returns (bool ok) {
        string memory sig = "exit(address,uint256)";
        (ok,) = address(daiA).call(abi.encodeWithSignature(sig, usr, fxp18Int));
    }
    function test_gem_join() public {
        collateralToken.mint(20 ether);
        collateralToken.approve(address(gemA), 20 ether);
        assertTrue( try_join_gem(address(this), 10 ether));
        assertEq(cdpCore.collateralToken("collateralToken", me), 10 ether);
        assertTrue( try_cage(address(gemA)));
        assertTrue(!try_join_gem(address(this), 10 ether));
        assertEq(cdpCore.collateralToken("collateralToken", me), 10 ether);
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }
    function test_dai_exit() public {
        address cdp = address(this);
        cdpCore.mint(address(this), 100 ether);
        cdpCore.grantAccess(address(daiA));
        assertTrue( try_exit_dai(cdp, 40 ether));
        assertEq(dai.balanceOf(address(this)), 40 ether);
        assertEq(cdpCore.dai(me),              fxp45Int(60 ether));
        assertTrue( try_cage(address(daiA)));
        assertTrue(!try_exit_dai(cdp, 40 ether));
        assertEq(dai.balanceOf(address(this)), 40 ether);
        assertEq(cdpCore.dai(me),              fxp45Int(60 ether));
    }
    function test_dai_exit_join() public {
        address cdp = address(this);
        cdpCore.mint(address(this), 100 ether);
        cdpCore.grantAccess(address(daiA));
        daiA.exit(cdp, 60 ether);
        dai.approve(address(daiA), uint(-1));
        daiA.deposit(cdp, 30 ether);
        assertEq(dai.balanceOf(address(this)),     30 ether);
        assertEq(cdpCore.dai(me),                  fxp45Int(70 ether));
    }
    function test_cage_no_access() public {
        gemA.deauthorizeAddress(address(this));
        assertTrue(!try_cage(address(gemA)));
        daiA.deauthorizeAddress(address(this));
        assertTrue(!try_cage(address(daiA)));
    }
}

interface FlipLike {
    struct Bid {
        uint256 bid;
        uint256 lot;
        address highBidder;  // high bidder
        uint48  bidExpiry;  // expiry time
        uint48  auctionEndTimestamp;
        address cdp;
        address incomeRecipient;
        uint256 tab;
    }
    function bids(uint) external view returns (
        uint256 bid,
        uint256 lot,
        address highBidder,
        uint48  bidExpiry,
        uint48  auctionEndTimestamp,
        address usr,
        address incomeRecipient,
        uint256 tab
    );
}

contract BiteTest is DSTest {
    Hevm hevm;

    TestVat cdpCore;
    TestVow settlement;
    Liquidation     cat;
    DSToken gold;
    Jug     stabilityFeeDatabase;

    GemJoin gemA;

    Flipper collateralForDaiAuction;
    BadDebtAuction flop;
    SurplusAuction flap;

    DSToken gov;

    address me;

    uint256 constant MLN = 10 ** 6;
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    function try_frob(bytes32 collateralType, int collateralBalance, int stablecoinDebt) public returns (bool ok) {
        string memory sig = "modifyCDP(bytes32,address,address,address,int256,int256)";
        address self = address(this);
        (ok,) = address(cdpCore).call(abi.encodeWithSignature(sig, collateralType, self, self, self, collateralBalance, stablecoinDebt));
    }

    function fxp27Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 9;
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }

    function collateralToken(bytes32 collateralType, address cdp) internal view returns (uint) {
        return cdpCore.collateralToken(collateralType, cdp);
    }
    function collateralBalance(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); art_;
        return ink_;
    }
    function stablecoinDebt(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); ink_;
        return art_;
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        gov = new DSToken('GOV');
        gov.mint(100 ether);

        cdpCore = new TestVat();
        cdpCore = cdpCore;

        flap = new SurplusAuction(address(cdpCore), address(gov));
        flop = new BadDebtAuction(address(cdpCore), address(gov));

        settlement = new TestVow(address(cdpCore), address(flap), address(flop));
        flap.authorizeAddress(address(settlement));
        flop.authorizeAddress(address(settlement));

        stabilityFeeDatabase = new Jug(address(cdpCore));
        stabilityFeeDatabase.createNewCollateralType("gold");
        stabilityFeeDatabase.changeConfig("settlement", address(settlement));
        cdpCore.authorizeAddress(address(stabilityFeeDatabase));

        cat = new Liquidation(address(cdpCore));
        cat.changeConfig("settlement", address(settlement));
        cat.changeConfig("box", fxp45Int((10 ether) * MLN));
        cdpCore.authorizeAddress(address(cat));
        settlement.authorizeAddress(address(cat));

        gold = new DSToken("GEM");
        gold.mint(1000 ether);

        cdpCore.createNewCollateralType("gold");
        gemA = new GemJoin(address(cdpCore), "gold", address(gold));
        cdpCore.authorizeAddress(address(gemA));
        gold.approve(address(gemA));
        gemA.deposit(address(this), 1000 ether);

        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(1 ether));
        cdpCore.changeConfig("gold", "debtCeiling", fxp45Int(1000 ether));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(1000 ether));
        collateralForDaiAuction = new Flipper(address(cdpCore), address(cat), "gold");
        collateralForDaiAuction.authorizeAddress(address(cat));
        cat.authorizeAddress(address(collateralForDaiAuction));
        cat.changeConfig("gold", "collateralForDaiAuction", address(collateralForDaiAuction));
        cat.changeConfig("gold", "liquidationPenalty", 1 ether);

        cdpCore.authorizeAddress(address(collateralForDaiAuction));
        cdpCore.authorizeAddress(address(flap));
        cdpCore.authorizeAddress(address(flop));

        cdpCore.grantAccess(address(collateralForDaiAuction));
        cdpCore.grantAccess(address(flop));
        gold.approve(address(cdpCore));
        gov.approve(address(flap));

        me = address(this);
    }

    function test_set_dunk_multiple_ilks() public {
        cat.changeConfig("gold",   "dunk", fxp45Int(111111 ether));
        (,, uint256 goldDunk) = cat.collateralTypes("gold");
        assertEq(goldDunk, fxp45Int(111111 ether));
        cat.changeConfig("silver", "dunk", fxp45Int(222222 ether));
        (,, uint256 silverDunk) = cat.collateralTypes("silver");
        assertEq(silverDunk, fxp45Int(222222 ether));
    }
    function test_cat_set_box() public {
        assertEq(cat.box(), fxp45Int((10 ether) * MLN));
        cat.changeConfig("box", fxp45Int((20 ether) * MLN));
        assertEq(cat.box(), fxp45Int((20 ether) * MLN));
    }
    function test_bite_under_dunk() public {
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 40 ether, 100 ether);
        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2 ether));  // now unsafe

        cat.changeConfig("gold", "dunk", fxp45Int(111 ether));
        cat.changeConfig("gold", "liquidationPenalty", 1.1 ether);

        uint auction = cat.liquidateCdp("gold", address(this));
        // the full CDP is liquidated
        assertEq(collateralBalance("gold", address(this)), 0);
        assertEq(stablecoinDebt("gold", address(this)), 0);
        // all debt goes to the settlement
        assertEq(settlement.totalDebt(), fxp45Int(100 ether));
        // auction is for all collateral
        (, uint lot,,,,,, uint tab) = collateralForDaiAuction.bids(auction);
        assertEq(lot,        40 ether);
        assertEq(tab,   fxp45Int(110 ether));
    }
    function test_bite_over_dunk() public {
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 40 ether, 100 ether);
        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2 ether));  // now unsafe

        cat.changeConfig("gold", "liquidationPenalty", 1.1 ether);
        cat.changeConfig("gold", "dunk", fxp45Int(82.5 ether));

        uint auction = cat.liquidateCdp("gold", address(this));
        // the CDP is partially liquidated
        assertEq(collateralBalance("gold", address(this)), 10 ether);
        assertEq(stablecoinDebt("gold", address(this)), 25 ether);
        // a fraction of the debt goes to the settlement
        assertEq(settlement.totalDebt(), fxp45Int(75 ether));
        // auction is for a fraction of the collateral
        (, uint lot,,,,,, uint tab) = FlipLike(address(collateralForDaiAuction)).bids(auction);
        assertEq(lot,       30 ether);
        assertEq(tab,   fxp45Int(82.5 ether));
    }

    function test_happy_bite() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 40 ether, 100 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2 ether));  // now unsafe
        cat.changeConfig("gold", "liquidationPenalty", 1.1 ether);

        assertEq(collateralBalance("gold", address(this)),  40 ether);
        assertEq(stablecoinDebt("gold", address(this)), 100 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 960 ether);

        cat.changeConfig("gold", "dunk", fxp45Int(200 ether));  // => liquidateCdp everything
        assertEq(cat.litter(), 0);
        uint auction = cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(110 ether));
        assertEq(collateralBalance("gold", address(this)), 0);
        assertEq(stablecoinDebt("gold", address(this)), 0);
        assertEq(settlement.badDebt(now),   fxp45Int(100 ether));
        assertEq(collateralToken("gold", address(this)), 960 ether);

        assertEq(cdpCore.dai(address(settlement)), fxp45Int(0 ether));
        cdpCore.mint(address(this), 100 ether);  // magic up some dai for bidding
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 40 ether,   fxp45Int(1 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 40 ether, fxp45Int(110 ether));

        assertEq(cdpCore.dai(address(this)),  fxp45Int(90 ether));
        assertEq(collateralToken("gold", address(this)), 960 ether);
        collateralForDaiAuction.makeBidDecreaseLotSize(auction, 38 ether,  fxp45Int(110 ether));
        assertEq(cdpCore.dai(address(this)),  fxp45Int(90 ether));
        assertEq(collateralToken("gold", address(this)), 962 ether);
        assertEq(settlement.badDebt(now),     fxp45Int(100 ether));

        hevm.warp(now + 4 hours);
        assertEq(cat.litter(), fxp45Int(110 ether));
        collateralForDaiAuction.claimWinningBid(auction);
        assertEq(cat.litter(), 0);
        assertEq(cdpCore.dai(address(settlement)),  fxp45Int(110 ether));
    }

    // tests a partial lot liquidation because it would fill the literbox
    function test_partial_litterbox() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cat.changeConfig("box", fxp45Int(75 ether));
        cat.changeConfig("gold", "dunk", fxp45Int(100 ether));
        assertEq(cat.box(), fxp45Int(75 ether));
        assertEq(cat.litter(), 0);
        uint auction = cat.liquidateCdp("gold", address(this));

        assertEq(collateralBalance("gold", address(this)), 50 ether);
        assertEq(stablecoinDebt("gold", address(this)), 75 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 900 ether);

        assertEq(cdpCore.dai(address(this)),  fxp45Int(150 ether));
        assertEq(cdpCore.dai(address(settlement)),     fxp45Int(0 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int(1 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(149 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(75 ether));

        assertEq(collateralToken("gold", address(this)),  900 ether);
        collateralForDaiAuction.makeBidDecreaseLotSize(auction, 25 ether, fxp45Int(75 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 925 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));

        hevm.warp(now + 4 hours);
        collateralForDaiAuction.claimWinningBid(auction);
        assertEq(cat.litter(), 0);
        assertEq(collateralToken("gold", address(this)),  950 ether);
        assertEq(cdpCore.dai(address(this)),   fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(settlement)),    fxp45Int(75 ether));
    }

    // tests a partial lot liquidation because it would fill the literbox
    function test_partial_litterbox_realistic_values() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe
        cat.changeConfig("gold", "liquidationPenalty", 1.13 ether);

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        // To check this yourself, use the following debtMultiplierIncludingStabilityFee calculation (example 8%):
        //
        // $ bc -l <<< 'scale=27; e( l(1.08)/(60 * 60 * 24 * 365) )'
        uint256 EIGHT_PCT = 1000000002440418608258400030;
        stabilityFeeDatabase.changeConfig("gold", "duty", EIGHT_PCT);
        hevm.warp(now + 10 days);
        stabilityFeeDatabase.increaseStabilityFee("gold");
        (, uint debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes("gold");

        uint vowBalance = cdpCore.dai(address(settlement)); // Balance updates after cdpCore.changeDebtMultiplier is called from stabilityFeeDatabase

        cat.changeConfig("box", fxp45Int(75 ether));
        cat.changeConfig("gold", "dunk", fxp45Int(100 ether));
        assertEq(cat.box(), fxp45Int(75 ether));
        assertEq(cat.litter(), 0);
        uint auction = cat.liquidateCdp("gold", address(this));
        (,,,,,,,uint tab) = collateralForDaiAuction.bids(auction);

        assertTrue(cat.box() - cat.litter() < fxp27Int(1 ether)); // Rounding error to fill box
        assertEq(cat.litter(), tab);                         // tab = 74.9999... RAD

        uint256 changeInDebt = fxp45Int(75 ether) * WAD / debtMultiplierIncludingStabilityFee / 1.13 ether; // room / debtMultiplierIncludingStabilityFee / liquidationPenalty
        uint256 changeInCollateral = 100 ether * changeInDebt / 150 ether;

        assertEq(collateralBalance("gold", address(this)), 100 ether - changeInCollateral); // Taken in cdpCore.liquidateCDP
        assertEq(stablecoinDebt("gold", address(this)), 150 ether - changeInDebt); // Taken in cdpCore.liquidateCDP
        assertEq(settlement.badDebt(now), changeInDebt * debtMultiplierIncludingStabilityFee);               
        assertEq(collateralToken("gold", address(this)), 900 ether);

        assertEq(cdpCore.dai(address(this)), fxp45Int(150 ether));
        assertEq(cdpCore.dai(address(settlement)),  vowBalance);
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, changeInCollateral, fxp45Int( 1 ether));
        assertEq(cat.litter(), tab);
        assertEq(cdpCore.dai(address(this)), fxp45Int(149 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, changeInCollateral, tab);
        assertEq(cdpCore.dai(address(this)), fxp45Int(150 ether) - tab);

        assertEq(collateralToken("gold", address(this)),  900 ether);
        collateralForDaiAuction.makeBidDecreaseLotSize(auction, 25 ether, tab);
        assertEq(cat.litter(), tab);
        assertEq(cdpCore.dai(address(this)), fxp45Int(150 ether) - tab);
        assertEq(collateralToken("gold", address(this)), 900 ether + (changeInCollateral - 25 ether));
        assertEq(settlement.badDebt(now), changeInDebt * debtMultiplierIncludingStabilityFee);

        hevm.warp(now + 4 hours);
        collateralForDaiAuction.claimWinningBid(auction);
        assertEq(cat.litter(), 0);
        assertEq(collateralToken("gold", address(this)),  900 ether + changeInCollateral); // (transferCollateral another 25 fxp18Int into collateralToken)
        assertEq(cdpCore.dai(address(this)), fxp45Int(150 ether) - tab);  
        assertEq(cdpCore.dai(address(settlement)),  vowBalance + tab);
    }

    // tests a partial lot liquidation that fill litterbox
    function testFail_fill_litterbox() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cat.changeConfig("box", fxp45Int(75 ether));
        cat.changeConfig("gold", "dunk", fxp45Int(100 ether));
        assertEq(cat.box(), fxp45Int(75 ether));
        assertEq(cat.litter(), 0);
        cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(collateralBalance("gold", address(this)), 50 ether);
        assertEq(stablecoinDebt("gold", address(this)), 75 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 900 ether);

        // this liquidateCdp puts us over the litterbox
        cat.liquidateCdp("gold", address(this));
    }

    // Tests for multiple bites where second liquidateCdp has a dusty amount for room
    function testFail_dusty_litterbox() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 50 ether, 80 ether + 1);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 50 ether);
        assertEq(stablecoinDebt("gold", address(this)), 80 ether + 1);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 950 ether);

        cat.changeConfig("box",  fxp45Int(100 ether));
        cdpCore.changeConfig("gold", "dust", fxp45Int(20 ether));
        cat.changeConfig("gold", "dunk", fxp45Int(100 ether));

        assertEq(cat.box(), fxp45Int(100 ether));
        assertEq(cat.litter(), 0);
        cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(80 ether + 1)); // room is now dusty
        assertEq(collateralBalance("gold", address(this)), 0 ether);
        assertEq(stablecoinDebt("gold", address(this)), 0 ether);
        assertEq(settlement.badDebt(now), fxp45Int(80 ether + 1));
        assertEq(collateralToken("gold", address(this)), 950 ether);

        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 850 ether);

        assertTrue(cat.box() - cat.litter() < fxp45Int(20 ether)); // room < dust

        // // this liquidateCdp puts us over the litterbox
        cat.liquidateCdp("gold", address(this));
    }

    // test liquidations that fill the litterbox claimWinningBid them then liquidate more
    function test_partial_litterbox_multiple_bites() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        // tag=4, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cat.changeConfig("box", fxp45Int(75 ether));
        cat.changeConfig("gold", "dunk", fxp45Int(100 ether));
        assertEq(cat.box(), fxp45Int(75 ether));
        assertEq(cat.litter(), 0);
        uint auction = cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(collateralBalance("gold", address(this)), 50 ether);
        assertEq(stablecoinDebt("gold", address(this)), 75 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 900 ether);

        assertEq(cdpCore.dai(address(this)), fxp45Int(150 ether));
        assertEq(cdpCore.dai(address(settlement)),    fxp45Int(0 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int( 1 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(149 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(75 ether));

        assertEq(collateralToken("gold", address(this)),  900 ether);
        collateralForDaiAuction.makeBidDecreaseLotSize(auction, 25 ether, fxp45Int(75 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 925 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));

        // From testFail_fill_litterbox() we know another liquidateCdp() here would
        // fail with a 'Liquidation/liquidation-limit-hit' revert.  So let's claimWinningBid()
        // and then liquidateCdp() again once there is more capacity in the litterbox

        hevm.warp(now + 4 hours);
        collateralForDaiAuction.claimWinningBid(auction);
        assertEq(cat.litter(), 0);
        assertEq(collateralToken("gold", address(this)), 950 ether);
        assertEq(cdpCore.dai(address(this)),  fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(settlement)),   fxp45Int(75 ether));

        // now liquidateCdp more
        auction = cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(collateralBalance("gold", address(this)), 0);
        assertEq(stablecoinDebt("gold", address(this)), 0);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 950 ether);

        assertEq(cdpCore.dai(address(this)), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(settlement)),  fxp45Int(75 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int( 1 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), fxp45Int(74 ether));
        collateralForDaiAuction.makeBidIncreaseBidSize(auction, 50 ether, fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), 0);

        assertEq(collateralToken("gold", address(this)),  950 ether);
        collateralForDaiAuction.makeBidDecreaseLotSize(auction, 25 ether, fxp45Int(75 ether));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(cdpCore.dai(address(this)), 0);
        assertEq(collateralToken("gold", address(this)), 975 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));

        hevm.warp(now + 4 hours);
        collateralForDaiAuction.claimWinningBid(auction);
        assertEq(cat.litter(), 0);
        assertEq(collateralToken("gold", address(this)),  1000 ether);
        assertEq(cdpCore.dai(address(this)), 0);
        assertEq(cdpCore.dai(address(settlement)),  fxp45Int(150 ether));
    }

    function testFail_null_auctions_dart_realistic_values() public {
        cdpCore.changeConfig("gold", "dust", fxp45Int(100 ether));
        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(2.5 ether));
        cdpCore.changeConfig("gold", "debtCeiling", fxp45Int(2000 ether));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(2000 ether));
        cdpCore.changeDebtMultiplier("gold", address(settlement), int256(fxp27Int(0.25 ether)));
        cdpCore.modifyCDP("gold", me, me, me, 800 ether, 2000 ether);

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        // slightly contrived value to leave tiny amount of room post-liquidation
        cat.changeConfig("box", fxp45Int(1130 ether) + 1);
        cat.changeConfig("gold", "dunk", fxp45Int(1130 ether));
        cat.changeConfig("gold", "liquidationPenalty", 1.13 ether);
        cat.liquidateCdp("gold", me);
        assertEq(cat.litter(), fxp45Int(1130 ether));
        uint room = cat.box() - cat.litter();
        assertEq(room, 1);
        (, uint256 debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes("gold");
        (, uint256 liquidationPenalty,) = cat.collateralTypes("gold");
        assertEq(room * (1 ether) / debtMultiplierIncludingStabilityFee / liquidationPenalty, 0);

        // Biting any non-zero amount of debt would overflow the box,
        // so this should revert and not create a null auction.
        // In this case we're protected by the dustiness check on room.
        cat.liquidateCdp("gold", me);
    }

    function testFail_null_auctions_dart_artificial_values() public {
        // artificially tiny dust value, e.g. due to misconfiguration
        cdpCore.changeConfig("dust", "dust", 1);
        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 200 ether);

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        // contrived value to leave tiny amount of room post-liquidation
        cat.changeConfig("box", fxp45Int(113 ether) + 2);
        cat.changeConfig("gold", "dunk", fxp45Int(113  ether));
        cat.changeConfig("gold", "liquidationPenalty", 1.13 ether);
        cat.liquidateCdp("gold", me);
        assertEq(cat.litter(), fxp45Int(113 ether));
        uint room = cat.box() - cat.litter();
        assertEq(room, 2);
        (, uint256 debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes("gold");
        (, uint256 liquidationPenalty,) = cat.collateralTypes("gold");
        assertEq(room * (1 ether) / debtMultiplierIncludingStabilityFee / liquidationPenalty, 0);

        // Biting any non-zero amount of debt would overflow the box,
        // so this should revert and not create a null auction.
        // The dustiness check on room doesn't apply here, so additional
        // logic is needed to make this test pass.
        cat.liquidateCdp("gold", me);
    }

    function testFail_null_auctions_dink_artificial_values() public {
        // we're going to make 1 wei of collateralBalance worth 250
        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(250 ether) * 1 ether);
        cat.changeConfig("gold", "dunk", fxp45Int(50 ether));
        cdpCore.modifyCDP("gold", me, me, me, 1, 100 ether);

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', 1);  // massive price crash, now unsafe

        // This should leave us with 0 changeInCollateral value, and fail
        cat.liquidateCdp("gold", me);
    }

    function testFail_null_auctions_dink_artificial_values_2() public {
        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(2000 ether));
        cdpCore.changeConfig("gold", "debtCeiling", fxp45Int(20000 ether));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(20000 ether));
        cdpCore.modifyCDP("gold", me, me, me, 10 ether, 15000 ether);

        cat.changeConfig("box", fxp45Int(1000000 ether));  // plenty of room

        // misconfigured dunk (e.g. precision factor incorrect in spell)
        cat.changeConfig("gold", "dunk", fxp45Int(100));

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1000 ether));  // now unsafe

        // This should leave us with 0 changeInCollateral value, and fail
        cat.liquidateCdp("gold", me);
    }

    function testFail_null_spot_value() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(1 ether));  // now unsafe

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cat.changeConfig("gold", "dunk", fxp45Int(75 ether));
        assertEq(cat.litter(), 0);
        cat.liquidateCdp("gold", address(this));
        assertEq(cat.litter(), fxp45Int(75 ether));
        assertEq(collateralBalance("gold", address(this)), 50 ether);
        assertEq(stablecoinDebt("gold", address(this)), 75 ether);
        assertEq(settlement.badDebt(now), fxp45Int(75 ether));
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', 0);

        // this should fail because maxDaiPerUnitOfCollateral is 0
        cat.liquidateCdp("gold", address(this));
    }

    function testFail_vault_is_safe() public {
        // maxDaiPerUnitOfCollateral = tag / (par . mat)
        // tag=5, mat=2
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 100 ether, 150 ether);

        assertEq(collateralBalance("gold", address(this)), 100 ether);
        assertEq(stablecoinDebt("gold", address(this)), 150 ether);
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), 0 ether);
        assertEq(collateralToken("gold", address(this)), 900 ether);

        cat.changeConfig("gold", "dunk", fxp45Int(75 ether));
        assertEq(cat.litter(), 0);

        // this should fail because the vault is isCdpSafe
        cat.liquidateCdp("gold", address(this));
    }

    function test_floppy_bite() public {
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2.5 ether));
        cdpCore.modifyCDP("gold", me, me, me, 40 ether, 100 ether);
        cdpCore.changeConfig("gold", 'maxDaiPerUnitOfCollateral', fxp27Int(2 ether));  // now unsafe

        cat.changeConfig("gold", "dunk", fxp45Int(200 ether));  // => liquidateCdp everything
        assertEq(settlement.badDebt(now), fxp45Int(  0 ether));
        cat.liquidateCdp("gold", address(this));
        assertEq(settlement.badDebt(now), fxp45Int(100 ether));

        assertEq(settlement.totalDebtInDebtQueue(), fxp45Int(100 ether));
        settlement.removeDebtFromDebtQueue(now);
        assertEq(settlement.totalDebtInDebtQueue(), fxp45Int(  0 ether));
        assertEq(settlement.totalNonQueuedNonAuctionDebt(), fxp45Int(100 ether));
        assertEq(settlement.totalSurplus(), fxp45Int(  0 ether));
        assertEq(settlement.totalOnAuctionDebt(), fxp45Int(  0 ether));

        settlement.changeConfig("debtAuctionLotSize", fxp45Int(10 ether));
        settlement.changeConfig("dump", 2000 ether);
        uint f1 = settlement.startBadDebtAuction();
        assertEq(settlement.totalNonQueuedNonAuctionDebt(),  fxp45Int(90 ether));
        assertEq(settlement.totalSurplus(),  fxp45Int( 0 ether));
        assertEq(settlement.totalOnAuctionDebt(),  fxp45Int(10 ether));
        flop.makeBidDecreaseLotSize(f1, 1000 ether, fxp45Int(10 ether));
        assertEq(settlement.totalNonQueuedNonAuctionDebt(),  fxp45Int(90 ether));
        assertEq(settlement.totalSurplus(),  fxp45Int( 0 ether));
        assertEq(settlement.totalOnAuctionDebt(),  fxp45Int( 0 ether));

        assertEq(gov.balanceOf(address(this)),  100 ether);
        hevm.warp(now + 4 hours);
        gov.setOwner(address(flop));
        flop.claimWinningBid(f1);
        assertEq(gov.balanceOf(address(this)), 1100 ether);
    }

    function test_flappy_bite() public {
        // get some surplus
        cdpCore.mint(address(settlement), 100 ether);
        assertEq(cdpCore.dai(address(settlement)),    fxp45Int(100 ether));
        assertEq(gov.balanceOf(address(this)), 100 ether);

        settlement.changeConfig("surplusAuctionLotSize", fxp45Int(100 ether));
        assertEq(settlement.totalDebt(), 0 ether);
        uint id = settlement.startSurplusAuction();

        assertEq(cdpCore.dai(address(this)),     fxp45Int(0 ether));
        assertEq(gov.balanceOf(address(this)), 100 ether);
        flap.makeBidIncreaseBidSize(id, fxp45Int(100 ether), 10 ether);
        hevm.warp(now + 4 hours);
        gov.setOwner(address(flap));
        flap.claimWinningBid(id);
        assertEq(cdpCore.dai(address(this)),     fxp45Int(100 ether));
        assertEq(gov.balanceOf(address(this)),    90 ether);
    }
}

contract FoldTest is DSTest {
    CDPCore cdpCore;

    function fxp27Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 9;
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }
    function tab(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); ink_;
        (uint Art_, uint debtMultiplierIncludingStabilityFee, uint maxDaiPerUnitOfCollateral, uint debtCeiling, uint dust) = cdpCore.collateralTypes(collateralType);
        Art_; maxDaiPerUnitOfCollateral; debtCeiling; dust;
        return art_ * debtMultiplierIncludingStabilityFee;
    }
    function jam(bytes32 collateralType, address cdp) internal view returns (uint) {
        (uint ink_, uint art_) = cdpCore.cdps(collateralType, cdp); art_;
        return ink_;
    }

    function setUp() public {
        cdpCore = new CDPCore();
        cdpCore.createNewCollateralType("gold");
        cdpCore.changeConfig("totalDebtCeiling", fxp45Int(100 ether));
        cdpCore.changeConfig("gold", "debtCeiling", fxp45Int(100 ether));
    }
    function increaseCDPDebt(bytes32 collateralType, uint dai) internal {
        cdpCore.changeConfig("totalDebtCeiling", fxp45Int(dai));
        cdpCore.changeConfig(collateralType, "debtCeiling", fxp45Int(dai));
        cdpCore.changeConfig(collateralType, "maxDaiPerUnitOfCollateral", 10 ** 27 * 10000 ether);
        address self = address(this);
        cdpCore.modifyUsersCollateralBalance(collateralType, self,  10 ** 27 * 1 ether);
        cdpCore.modifyCDP(collateralType, self, self, self, int(1 ether), int(dai));
    }
    function test_fold() public {
        address self = address(this);
        address ali  = address(bytes20("ali"));
        increaseCDPDebt("gold", 1 ether);

        assertEq(tab("gold", self), fxp45Int(1.00 ether));
        cdpCore.changeDebtMultiplier("gold", ali,   int(fxp27Int(0.05 ether)));
        assertEq(tab("gold", self), fxp45Int(1.05 ether));
        assertEq(cdpCore.dai(ali),      fxp45Int(0.05 ether));
    }
}

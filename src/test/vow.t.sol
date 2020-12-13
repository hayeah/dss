pragma solidity >=0.5.12;

import "ds-test/test.sol";

import {BadDebtAuction as Flop} from './flop.t.sol';
import {SurplusAuction as Flap} from './flap.t.sol';
import {TestVat as  CDPCore} from './cdpCore.t.sol';
import {Settlement}     from '../settlement.sol';

interface Hevm {
    function warp(uint256) external;
}

contract Gem {
    mapping (address => uint256) public balanceOf;
    function mint(address usr, uint fxp45Int) public {
        balanceOf[usr] += fxp45Int;
    }
}

contract VowTest is DSTest {
    Hevm hevm;

    CDPCore  cdpCore;
    Settlement  settlement;
    Flop flop;
    Flap flap;
    Gem  gov;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new CDPCore();

        gov  = new Gem();
        flop = new Flop(address(cdpCore), address(gov));
        flap = new Flap(address(cdpCore), address(gov));

        settlement = new Settlement(address(cdpCore), address(flap), address(flop));
        flap.authorizeAddress(address(settlement));
        flop.authorizeAddress(address(settlement));

        settlement.changeConfig("surplusAuctionLotSize", fxp45Int(100 ether));
        settlement.changeConfig("debtAuctionLotSize", fxp45Int(100 ether));
        settlement.changeConfig("dump", 200 ether);

        cdpCore.grantAccess(address(flop));
    }

    function try_flog(uint era) internal returns (bool ok) {
        string memory sig = "removeDebtFromDebtQueue(uint256)";
        (ok,) = address(settlement).call(abi.encodeWithSignature(sig, era));
    }
    function try_dent(uint id, uint lot, uint bid) internal returns (bool ok) {
        string memory sig = "makeBidDecreaseLotSize(uint256,uint256,uint256)";
        (ok,) = address(flop).call(abi.encodeWithSignature(sig, id, lot, bid));
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
    function can_startSurplusAuction() public returns (bool) {
        string memory sig = "startSurplusAuction()";
        bytes memory data = abi.encodeWithSignature(sig);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", settlement, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function can_startBadDebtAuction() public returns (bool) {
        string memory sig = "startBadDebtAuction()";
        bytes memory data = abi.encodeWithSignature(sig);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", settlement, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }

    uint constant ONE = 10 ** 27;
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * ONE;
    }

    function issueBadDebt(address who, uint fxp18Int) internal {
        settlement.addDebtToDebtQueue(fxp45Int(fxp18Int));
        cdpCore.createNewCollateralType('');
        cdpCore.issueBadDebt(address(settlement), who, fxp45Int(fxp18Int));
    }
    function removeDebtFromDebtQueue(uint fxp18Int) internal {
        issueBadDebt(address(0), fxp18Int);  // issueBadDebt dai into the zero address
        settlement.removeDebtFromDebtQueue(now);
    }
    function settleDebtUsingSurplus(uint fxp18Int) internal {
        settlement.settleDebtUsingSurplus(fxp45Int(fxp18Int));
    }

    function test_change_flap_startBadDebtAuction() public {
        Flap newFlap = new Flap(address(cdpCore), address(gov));
        Flop newFlop = new Flop(address(cdpCore), address(gov));

        newFlap.authorizeAddress(address(settlement));
        newFlop.authorizeAddress(address(settlement));

        assertEq(cdpCore.can(address(settlement), address(flap)), 1);
        assertEq(cdpCore.can(address(settlement), address(newFlap)), 0);

        settlement.changeConfig('surplusAuction', address(newFlap));
        settlement.changeConfig('badDebtAuction', address(newFlop));

        assertEq(address(settlement.surplusAuction()), address(newFlap));
        assertEq(address(settlement.badDebtAuction()), address(newFlop));

        assertEq(cdpCore.can(address(settlement), address(flap)), 0);
        assertEq(cdpCore.can(address(settlement), address(newFlap)), 1);
    }

    function test_flog_wait() public {
        assertEq(settlement.debtQueueLength(), 0);
        settlement.changeConfig('debtQueueLength', uint(100 seconds));
        assertEq(settlement.debtQueueLength(), 100 seconds);

        uint bidExpiry = now;                                                                                                                                                       
        settlement.addDebtToDebtQueue(100 ether);                                                     
        hevm.warp(bidExpiry + 99 seconds);                                             
        assertTrue(!try_flog(bidExpiry) );                                             
        hevm.warp(bidExpiry + 100 seconds);                                            
        assertTrue( try_flog(bidExpiry) ); 
    }

    function test_no_restartBadDebtAuction() public {
        removeDebtFromDebtQueue(100 ether);
        assertTrue( can_startBadDebtAuction() );
        settlement.startBadDebtAuction();
        assertTrue(!can_startBadDebtAuction() );
    }

    function test_no_flop_pending_joy() public {
        removeDebtFromDebtQueue(200 ether);

        cdpCore.mint(address(settlement), 100 ether);
        assertTrue(!can_startBadDebtAuction() );

        settleDebtUsingSurplus(100 ether);
        assertTrue( can_startBadDebtAuction() );
    }

    function test_startSurplusAuction() public {
        cdpCore.mint(address(settlement), 100 ether);
        assertTrue( can_startSurplusAuction() );
    }

    function test_no_flap_pending_sin() public {
        settlement.changeConfig("surplusAuctionLotSize", uint256(0 ether));
        removeDebtFromDebtQueue(100 ether);

        cdpCore.mint(address(settlement), 50 ether);
        assertTrue(!can_startSurplusAuction() );
    }
    function test_no_flap_nonzero_woe() public {
        settlement.changeConfig("surplusAuctionLotSize", uint256(0 ether));
        removeDebtFromDebtQueue(100 ether);
        cdpCore.mint(address(settlement), 50 ether);
        assertTrue(!can_startSurplusAuction() );
    }
    function test_no_flap_pending_startBadDebtAuction() public {
        removeDebtFromDebtQueue(100 ether);
        settlement.startBadDebtAuction();

        cdpCore.mint(address(settlement), 100 ether);

        assertTrue(!can_startSurplusAuction() );
    }
    function test_no_flap_pending_heal() public {
        removeDebtFromDebtQueue(100 ether);
        uint id = settlement.startBadDebtAuction();

        cdpCore.mint(address(this), 100 ether);
        flop.makeBidDecreaseLotSize(id, 0 ether, fxp45Int(100 ether));

        assertTrue(!can_startSurplusAuction() );
    }

    function test_no_surplus_after_good_startBadDebtAuction() public {
        removeDebtFromDebtQueue(100 ether);
        uint id = settlement.startBadDebtAuction();
        cdpCore.mint(address(this), 100 ether);

        flop.makeBidDecreaseLotSize(id, 0 ether, fxp45Int(100 ether));  // flop succeeds..

        assertTrue(!can_startSurplusAuction() );
    }

    function test_multiple_flop_dents() public {
        removeDebtFromDebtQueue(100 ether);
        uint id = settlement.startBadDebtAuction();

        cdpCore.mint(address(this), 100 ether);
        assertTrue(try_dent(id, 2 ether,  fxp45Int(100 ether)));

        cdpCore.mint(address(this), 100 ether);
        assertTrue(try_dent(id, 1 ether,  fxp45Int(100 ether)));
    }
}

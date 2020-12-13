pragma solidity >=0.5.12;

import "ds-test/test.sol";
import {CDPCore} from '../cdpCore.sol';
import {Savings} from '../pot.sol';

interface Hevm {
    function warp(uint256) external;
}

contract DSRTest is DSTest {
    Hevm hevm;

    CDPCore cdpCore;
    Savings pot;

    address settlement;
    address self;
    address potb;

    function fxp45Int(uint wad_) internal pure returns (uint) {
        return wad_ * 10 ** 27;
    }
    function fxp18Int(uint rad_) internal pure returns (uint) {
        return rad_ / 10 ** 27;
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new CDPCore();
        pot = new Savings(address(cdpCore));
        cdpCore.authorizeAddress(address(pot));
        self = address(this);
        potb = address(pot);

        settlement = address(bytes20("settlement"));
        pot.changeConfig("settlement", settlement);

        cdpCore.issueBadDebt(self, self, fxp45Int(100 ether));
        cdpCore.grantAccess(address(pot));
    }
    function test_save_0d() public {
        assertEq(cdpCore.dai(self), fxp45Int(100 ether));

        pot.deposit(100 ether);
        assertEq(fxp18Int(cdpCore.dai(self)),   0 ether);
        assertEq(pot.daiSavings(self),      100 ether);

        pot.increaseStabilityFee();

        pot.exit(100 ether);
        assertEq(fxp18Int(cdpCore.dai(self)), 100 ether);
    }
    function test_save_1d() public {
        pot.deposit(100 ether);
        pot.changeConfig("daiSavingRate", uint(1000000564701133626865910626));  // 5% / day
        hevm.warp(now + 1 days);
        pot.increaseStabilityFee();
        assertEq(pot.daiSavings(self), 100 ether);
        pot.exit(100 ether);
        assertEq(fxp18Int(cdpCore.dai(self)), 105 ether);
    }
    function test_drip_multi() public {
        pot.deposit(100 ether);
        pot.changeConfig("daiSavingRate", uint(1000000564701133626865910626));  // 5% / day
        hevm.warp(now + 1 days);
        pot.increaseStabilityFee();
        assertEq(fxp18Int(cdpCore.dai(potb)),   105 ether);
        pot.changeConfig("daiSavingRate", uint(1000001103127689513476993127));  // 10% / day
        hevm.warp(now + 1 days);
        pot.increaseStabilityFee();
        assertEq(fxp18Int(cdpCore.badDebt(settlement)), 15.5 ether);
        assertEq(fxp18Int(cdpCore.dai(potb)), 115.5 ether);
        assertEq(pot.totalDaiSavings(),          100   ether);
        assertEq(pot.rateAccum() / 10 ** 9, 1.155 ether);
    }
    function test_drip_multi_inBlock() public {
        pot.increaseStabilityFee();
        uint collateralTypeLastStabilityFeeCollectionTimestamp = pot.collateralTypeLastStabilityFeeCollectionTimestamp();
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now);
        hevm.warp(now + 1 days);
        collateralTypeLastStabilityFeeCollectionTimestamp = pot.collateralTypeLastStabilityFeeCollectionTimestamp();
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now - 1 days);
        pot.increaseStabilityFee();
        collateralTypeLastStabilityFeeCollectionTimestamp = pot.collateralTypeLastStabilityFeeCollectionTimestamp();
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now);
        pot.increaseStabilityFee();
        collateralTypeLastStabilityFeeCollectionTimestamp = pot.collateralTypeLastStabilityFeeCollectionTimestamp();
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now);
    }
    function test_save_multi() public {
        pot.deposit(100 ether);
        pot.changeConfig("daiSavingRate", uint(1000000564701133626865910626));  // 5% / day
        hevm.warp(now + 1 days);
        pot.increaseStabilityFee();
        pot.exit(50 ether);
        assertEq(fxp18Int(cdpCore.dai(self)), 52.5 ether);
        assertEq(pot.totalDaiSavings(),          50.0 ether);

        pot.changeConfig("daiSavingRate", uint(1000001103127689513476993127));  // 10% / day
        hevm.warp(now + 1 days);
        pot.increaseStabilityFee();
        pot.exit(50 ether);
        assertEq(fxp18Int(cdpCore.dai(self)), 110.25 ether);
        assertEq(pot.totalDaiSavings(),            0.00 ether);
    }
    function test_fresh_chi() public {
        uint collateralTypeLastStabilityFeeCollectionTimestamp = pot.collateralTypeLastStabilityFeeCollectionTimestamp();
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now);
        hevm.warp(now + 1 days);
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp, now - 1 days);
        pot.increaseStabilityFee();
        pot.deposit(100 ether);
        assertEq(pot.daiSavings(self), 100 ether);
        pot.exit(100 ether);
        // if we exit in the same transaction we should not earn DSR
        assertEq(fxp18Int(cdpCore.dai(self)), 100 ether);
    }
    function testFail_stale_chi() public {
        pot.changeConfig("daiSavingRate", uint(1000000564701133626865910626));  // 5% / day
        pot.increaseStabilityFee();
        hevm.warp(now + 1 days);
        pot.deposit(100 ether);
    }
    function test_file() public {
        hevm.warp(now + 1);
        pot.increaseStabilityFee();
        pot.changeConfig("daiSavingRate", uint(1));
    }
    function testFail_file() public {
        hevm.warp(now + 1);
        pot.changeConfig("daiSavingRate", uint(1));
    }
}

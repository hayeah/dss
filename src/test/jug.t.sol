pragma solidity >=0.5.12;

import "ds-test/test.sol";

import {Jug} from "../stabilityFeeDatabase.sol";
import {CDPCore} from "../cdpCore.sol";


interface Hevm {
    function warp(uint256) external;
}

interface CDPCoreInterface {
    function collateralTypes(bytes32) external view returns (
        uint256 totalStablecoinDebt,
        uint256 debtMultiplierIncludingStabilityFee,
        uint256 maxDaiPerUnitOfCollateral,
        uint256 debtCeiling,
        uint256 dust
    );
}

contract Rpow is Jug {
    constructor(address core_) public Jug(core_){}

    function pRpow(uint x, uint n, uint b) public pure returns(uint) {
        return rpow(x, n, b);
    }
}


contract JugTest is DSTest {
    Hevm hevm;
    Jug stabilityFeeDatabase;
    CDPCore  cdpCore;

    function fxp45Int(uint wad_) internal pure returns (uint) {
        return wad_ * 10 ** 27;
    }
    function fxp18Int(uint rad_) internal pure returns (uint) {
        return rad_ / 10 ** 27;
    }
    function collateralTypeLastStabilityFeeCollectionTimestamp(bytes32 collateralType) internal view returns (uint) {
        (uint duty, uint rho_) = stabilityFeeDatabase.collateralTypes(collateralType); duty;
        return rho_;
    }
    function totalStablecoinDebt(bytes32 collateralType) internal view returns (uint ArtV) {
        (ArtV,,,,) = CDPCoreInterface(address(cdpCore)).collateralTypes(collateralType);
    }
    function debtMultiplierIncludingStabilityFee(bytes32 collateralType) internal view returns (uint rateV) {
        (, rateV,,,) = CDPCoreInterface(address(cdpCore)).collateralTypes(collateralType);
    }
    function debtCeiling(bytes32 collateralType) internal view returns (uint lineV) {
        (,,, lineV,) = CDPCoreInterface(address(cdpCore)).collateralTypes(collateralType);
    }

    address ali = address(bytes20("ali"));

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore  = new CDPCore();
        stabilityFeeDatabase = new Jug(address(cdpCore));
        cdpCore.authorizeAddress(address(stabilityFeeDatabase));
        cdpCore.createNewCollateralType("i");

        increaseCDPDebt("i", 100 ether);
    }
    function increaseCDPDebt(bytes32 collateralType, uint dai) internal {
        cdpCore.changeConfig("totalDebtCeiling", cdpCore.totalDebtCeiling() + fxp45Int(dai));
        cdpCore.changeConfig(collateralType, "debtCeiling", debtCeiling(collateralType) + fxp45Int(dai));
        cdpCore.changeConfig(collateralType, "maxDaiPerUnitOfCollateral", 10 ** 27 * 10000 ether);
        address self = address(this);
        cdpCore.modifyUsersCollateralBalance(collateralType, self,  10 ** 27 * 1 ether);
        cdpCore.modifyCDP(collateralType, self, self, self, int(1 ether), int(dai));
    }

    function test_drip_setup() public {
        hevm.warp(0);
        assertEq(uint(now), 0);
        hevm.warp(1);
        assertEq(uint(now), 1);
        hevm.warp(2);
        assertEq(uint(now), 2);
        assertEq(totalStablecoinDebt("i"), 100 ether);
    }
    function test_drip_updates_rho() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp("i"), now);

        stabilityFeeDatabase.changeConfig("i", "duty", 10 ** 27);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp("i"), now);
        hevm.warp(now + 1);
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp("i"), now - 1);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp("i"), now);
        hevm.warp(now + 1 days);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(collateralTypeLastStabilityFeeCollectionTimestamp("i"), now);
    }
    function test_drip_file() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("i", "duty", 10 ** 27);
        stabilityFeeDatabase.increaseStabilityFee("i");
        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day
    }
    function test_drip_0d() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day
        assertEq(cdpCore.dai(ali), fxp45Int(0 ether));
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(cdpCore.dai(ali), fxp45Int(0 ether));
    }
    function test_drip_1d() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("settlement", ali);

        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day
        hevm.warp(now + 1 days);
        assertEq(fxp18Int(cdpCore.dai(ali)), 0 ether);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 5 ether);
    }
    function test_drip_2d() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("settlement", ali);
        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day

        hevm.warp(now + 2 days);
        assertEq(fxp18Int(cdpCore.dai(ali)), 0 ether);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 10.25 ether);
    }
    function test_drip_3d() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("settlement", ali);

        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day
        hevm.warp(now + 3 days);
        assertEq(fxp18Int(cdpCore.dai(ali)), 0 ether);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 15.7625 ether);
    }
    function test_drip_negative_3d() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("settlement", ali);

        stabilityFeeDatabase.changeConfig("i", "duty", 999999706969857929985428567);  // -2.5% / day
        hevm.warp(now + 3 days);
        assertEq(fxp18Int(cdpCore.dai(address(this))), 100 ether);
        cdpCore.transfer(address(this), ali, fxp45Int(100 ether));
        assertEq(fxp18Int(cdpCore.dai(ali)), 100 ether);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 92.6859375 ether);
    }

    function test_drip_multi() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.changeConfig("settlement", ali);

        stabilityFeeDatabase.changeConfig("i", "duty", 1000000564701133626865910626);  // 5% / day
        hevm.warp(now + 1 days);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 5 ether);
        stabilityFeeDatabase.changeConfig("i", "duty", 1000001103127689513476993127);  // 10% / day
        hevm.warp(now + 1 days);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)),  15.5 ether);
        assertEq(fxp18Int(cdpCore.debt()),     115.5 ether);
        assertEq(debtMultiplierIncludingStabilityFee("i") / 10 ** 9, 1.155 ether);
    }
    function test_drip_base() public {
        cdpCore.createNewCollateralType("j");
        increaseCDPDebt("j", 100 ether);

        stabilityFeeDatabase.createNewCollateralType("i");
        stabilityFeeDatabase.createNewCollateralType("j");
        stabilityFeeDatabase.changeConfig("settlement", ali);

        stabilityFeeDatabase.changeConfig("i", "duty", 1050000000000000000000000000);  // 5% / second
        stabilityFeeDatabase.changeConfig("j", "duty", 1000000000000000000000000000);  // 0% / second
        stabilityFeeDatabase.changeConfig("base",  uint(50000000000000000000000000)); // 5% / second
        hevm.warp(now + 1);
        stabilityFeeDatabase.increaseStabilityFee("i");
        assertEq(fxp18Int(cdpCore.dai(ali)), 10 ether);
    }
    function test_file_duty() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        hevm.warp(now + 1);
        stabilityFeeDatabase.increaseStabilityFee("i");
        stabilityFeeDatabase.changeConfig("i", "duty", 1);
    }
    function testFail_file_duty() public {
        stabilityFeeDatabase.createNewCollateralType("i");
        hevm.warp(now + 1);
        stabilityFeeDatabase.changeConfig("i", "duty", 1);
    }
    function test_rpow() public {
        Rpow r = new Rpow(address(cdpCore));
        uint result = r.pRpow(uint(1000234891009084238901289093), uint(3724), uint(1e27));
        // python calc = 2.397991232255757e27 = 2397991232255757e12
        // expect 10 decimal precision
        assertEq(result / uint(1e17), uint(2397991232255757e12) / 1e17);
    }
}

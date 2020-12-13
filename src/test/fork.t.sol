pragma solidity >=0.5.12;

import "ds-test/test.sol";
import "ds-token/token.sol";

import {CDPCore} from '../cdpCore.sol';

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
    function pass() public {}
}

contract ForkTest is DSTest {
    CDPCore cdpCore;
    Usr ali;
    Usr bob;
    address a;
    address b;

    function fxp27Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 9;
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 27;
    }

    function setUp() public {
        cdpCore = new CDPCore();
        ali = new Usr(cdpCore);
        bob = new Usr(cdpCore);
        a = address(ali);
        b = address(bob);

        cdpCore.createNewCollateralType("collateralTokens");
        cdpCore.changeConfig("collateralTokens", "maxDaiPerUnitOfCollateral", fxp27Int(0.5  ether));
        cdpCore.changeConfig("collateralTokens", "debtCeiling", fxp45Int(1000 ether));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(1000 ether));

        cdpCore.modifyUsersCollateralBalance("collateralTokens", a, 8 ether);
    }
    function test_fork_to_self() public {
        ali.modifyCDP("collateralTokens", a, a, a, 8 ether, 4 ether);
        assertTrue( ali.can_fork("collateralTokens", a, a, 8 ether, 4 ether));
        assertTrue( ali.can_fork("collateralTokens", a, a, 4 ether, 2 ether));
        assertTrue(!ali.can_fork("collateralTokens", a, a, 9 ether, 4 ether));
    }
    function test_give_to_other() public {
        ali.modifyCDP("collateralTokens", a, a, a, 8 ether, 4 ether);
        assertTrue(!ali.can_fork("collateralTokens", a, b, 8 ether, 4 ether));
        bob.grantAccess(address(ali));
        assertTrue( ali.can_fork("collateralTokens", a, b, 8 ether, 4 ether));
    }
    function test_fork_to_other() public {
        ali.modifyCDP("collateralTokens", a, a, a, 8 ether, 4 ether);
        bob.grantAccess(address(ali));
        assertTrue( ali.can_fork("collateralTokens", a, b, 4 ether, 2 ether));
        assertTrue(!ali.can_fork("collateralTokens", a, b, 4 ether, 3 ether));
        assertTrue(!ali.can_fork("collateralTokens", a, b, 4 ether, 1 ether));
    }
    function test_fork_dust() public {
        ali.modifyCDP("collateralTokens", a, a, a, 8 ether, 4 ether);
        bob.grantAccess(address(ali));
        assertTrue( ali.can_fork("collateralTokens", a, b, 4 ether, 2 ether));
        cdpCore.changeConfig("collateralTokens", "dust", fxp45Int(1 ether));
        assertTrue( ali.can_fork("collateralTokens", a, b, 2 ether, 1 ether));
        assertTrue(!ali.can_fork("collateralTokens", a, b, 1 ether, 0.5 ether));
    }
}

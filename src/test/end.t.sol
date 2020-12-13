// SPDX-License-Identifier: AGPL-3.0-or-later

// auctionEndTimestamp.t.sol -- global settlement tests

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2018 Lev Livnev <lev@liv.nev.org.uk>
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

import "ds-test/test.sol";
import "ds-token/token.sol";
import "ds-value/value.sol";

import {CDPCore}  from '../cdpCore.sol';
import {Liquidation}  from '../cat.sol';
import {Settlement}  from '../settlement.sol';
import {Savings}  from '../pot.sol';
import {Flipper} from '../collateralForDaiAuction.sol';
import {SurplusAuction} from '../flap.sol';
import {BadDebtAuction} from '../flop.sol';
import {GemJoin} from '../deposit.sol';
import {End}  from '../auctionEndTimestamp.sol';
import {Spotter} from '../maxDaiPerUnitOfCollateral.sol';

interface Hevm {
    function warp(uint256) external;
}

contract Usr {
    CDPCore public cdpCore;
    End public auctionEndTimestamp;

    constructor(CDPCore core_, End end_) public {
        cdpCore  = core_;
        auctionEndTimestamp  = end_;
    }
    function modifyCDP(bytes32 collateralType, address u, address v, address w, int changeInCollateral, int changeInDebt) public {
        cdpCore.modifyCDP(collateralType, u, v, w, changeInCollateral, changeInDebt);
    }
    function transferCollateral(bytes32 collateralType, address src, address dst, uint256 fxp18Int) public {
        cdpCore.transferCollateral(collateralType, src, dst, fxp18Int);
    }
    function transfer(address src, address dst, uint256 fxp45Int) public {
        cdpCore.transfer(src, dst, fxp45Int);
    }
    function grantAccess(address usr) public {
        cdpCore.grantAccess(usr);
    }
    function exit(GemJoin gemA, address usr, uint fxp18Int) public {
        gemA.exit(usr, fxp18Int);
    }
    function transferCollateralFromCDP(bytes32 collateralType) public {
        auctionEndTimestamp.transferCollateralFromCDP(collateralType);
    }
    function pack(uint256 fxp45Int) public {
        auctionEndTimestamp.pack(fxp45Int);
    }
    function cash(bytes32 collateralType, uint fxp18Int) public {
        auctionEndTimestamp.cash(collateralType, fxp18Int);
    }
}

contract EndTest is DSTest {
    Hevm hevm;

    CDPCore   cdpCore;
    End   auctionEndTimestamp;
    Settlement   settlement;
    Savings   pot;
    Liquidation   cat;

    Spotter maxDaiPerUnitOfCollateral;

    struct CollateralType {
        DSValue pip;
        DSToken collateralToken;
        GemJoin gemA;
        Flipper collateralForDaiAuction;
    }

    mapping (bytes32 => CollateralType) collateralTypes;

    SurplusAuction flap;
    BadDebtAuction flop;

    uint constant WAD = 10 ** 18;
    uint constant RAY = 10 ** 27;
    uint constant MLN = 10 ** 6;

    function fxp27Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * 10 ** 9;
    }
    function fxp45Int(uint fxp18Int) internal pure returns (uint) {
        return fxp18Int * RAY;
    }
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / RAY;
    }
    function min(uint x, uint y) internal pure returns (uint z) {
        (x >= y) ? z = y : z = x;
    }
    function dai(address cdp) internal view returns (uint) {
        return cdpCore.dai(cdp) / RAY;
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
    function totalStablecoinDebt(bytes32 collateralType) internal view returns (uint) {
        (uint Art_, uint rate_, uint spot_, uint line_, uint dust_) = cdpCore.collateralTypes(collateralType);
        rate_; spot_; line_; dust_;
        return Art_;
    }
    function balanceOf(bytes32 collateralType, address usr) internal view returns (uint) {
        return collateralTypes[collateralType].collateralToken.balanceOf(usr);
    }

    function try_pot_file(bytes32 what, uint data) public returns(bool ok) {
        string memory sig = "changeConfig(bytes32, uint)";
        (ok,) = address(pot).call(abi.encodeWithSignature(sig, what, data));
    }

    function init_collateral(bytes32 name) internal returns (CollateralType memory) {
        DSToken coin = new DSToken(name);
        coin.mint(20 ether);

        DSValue pip = new DSValue();
        maxDaiPerUnitOfCollateral.changeConfig(name, "pip", address(pip));
        maxDaiPerUnitOfCollateral.changeConfig(name, "mat", fxp27Int(1.5 ether));
        // initial collateral price of 5
        pip.poke(bytes32(5 * WAD));

        cdpCore.createNewCollateralType(name);
        GemJoin gemA = new GemJoin(address(cdpCore), name, address(coin));

        // 1 coin = 6 dai and liquidation ratio is 200%
        cdpCore.changeConfig(name, "maxDaiPerUnitOfCollateral",    fxp27Int(3 ether));
        cdpCore.changeConfig(name, "debtCeiling", fxp45Int(1000 ether));

        coin.approve(address(gemA));
        coin.approve(address(cdpCore));

        cdpCore.authorizeAddress(address(gemA));

        Flipper collateralForDaiAuction = new Flipper(address(cdpCore), address(cat), name);
        cdpCore.grantAccess(address(collateralForDaiAuction));
        collateralForDaiAuction.authorizeAddress(address(auctionEndTimestamp));
        collateralForDaiAuction.authorizeAddress(address(cat));
        cat.authorizeAddress(address(collateralForDaiAuction));
        cat.changeConfig(name, "collateralForDaiAuction", address(collateralForDaiAuction));
        cat.changeConfig(name, "liquidationPenalty", 1 ether);
        cat.changeConfig(name, "dunk", fxp45Int(25000 ether));
        cat.changeConfig("box", fxp45Int((10 ether) * MLN));

        collateralTypes[name].pip = pip;
        collateralTypes[name].collateralToken = coin;
        collateralTypes[name].gemA = gemA;
        collateralTypes[name].collateralForDaiAuction = collateralForDaiAuction;

        return collateralTypes[name];
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        cdpCore = new CDPCore();
        DSToken gov = new DSToken('GOV');

        flap = new SurplusAuction(address(cdpCore), address(gov));
        flop = new BadDebtAuction(address(cdpCore), address(gov));
        gov.setOwner(address(flop));

        settlement = new Settlement(address(cdpCore), address(flap), address(flop));

        pot = new Savings(address(cdpCore));
        cdpCore.authorizeAddress(address(pot));
        pot.changeConfig("settlement", address(settlement));

        cat = new Liquidation(address(cdpCore));
        cat.changeConfig("settlement", address(settlement));
        cdpCore.authorizeAddress(address(cat));
        settlement.authorizeAddress(address(cat));

        maxDaiPerUnitOfCollateral = new Spotter(address(cdpCore));
        cdpCore.changeConfig("totalDebtCeiling",         fxp45Int(1000 ether));
        cdpCore.authorizeAddress(address(maxDaiPerUnitOfCollateral));

        auctionEndTimestamp = new End();
        auctionEndTimestamp.changeConfig("cdpCore", address(cdpCore));
        auctionEndTimestamp.changeConfig("cat", address(cat));
        auctionEndTimestamp.changeConfig("settlement", address(settlement));
        auctionEndTimestamp.changeConfig("pot", address(pot));
        auctionEndTimestamp.changeConfig("maxDaiPerUnitOfCollateral", address(maxDaiPerUnitOfCollateral));
        auctionEndTimestamp.changeConfig("debtQueueLength", 1 hours);
        cdpCore.authorizeAddress(address(auctionEndTimestamp));
        settlement.authorizeAddress(address(auctionEndTimestamp));
        maxDaiPerUnitOfCollateral.authorizeAddress(address(auctionEndTimestamp));
        pot.authorizeAddress(address(auctionEndTimestamp));
        cat.authorizeAddress(address(auctionEndTimestamp));
        flap.authorizeAddress(address(settlement));
        flop.authorizeAddress(address(settlement));
    }

    function test_cage_basic() public {
        assertEq(auctionEndTimestamp.isAlive(), 1);
        assertEq(cdpCore.isAlive(), 1);
        assertEq(cat.isAlive(), 1);
        assertEq(settlement.isAlive(), 1);
        assertEq(pot.isAlive(), 1);
        assertEq(settlement.badDebtAuction().isAlive(), 1);
        assertEq(settlement.surplusAuction().isAlive(), 1);
        auctionEndTimestamp.disable();
        assertEq(auctionEndTimestamp.isAlive(), 0);
        assertEq(cdpCore.isAlive(), 0);
        assertEq(cat.isAlive(), 0);
        assertEq(settlement.isAlive(), 0);
        assertEq(pot.isAlive(), 0);
        assertEq(settlement.badDebtAuction().isAlive(), 0);
        assertEq(settlement.surplusAuction().isAlive(), 0);
    }

    function test_cage_pot_drip() public {
        assertEq(pot.isAlive(), 1);
        pot.increaseStabilityFee();
        auctionEndTimestamp.disable();

        assertEq(pot.isAlive(), 0);
        assertEq(pot.daiSavingRate(), 10 ** 27);
        assertTrue(!try_pot_file("daiSavingRate", 10 ** 27 + 1));
    }

    // -- Scenario where there is one over-collateralised CDP
    // -- and there is no Settlement deficit or surplus
    function test_cage_collateralised() public {
        CollateralType memory gold = init_collateral("gold");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // ali's cdp has 0 collateralToken, 10 collateralBalance, 15 tab, 15 dai

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(15 ether));
        assertEq(cdpCore.badDebtSupply(), 0);

        // collateral price is 5
        gold.pip.poke(bytes32(5 * WAD));
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");
        auctionEndTimestamp.skim("gold", urn1);

        // local checks:
        assertEq(stablecoinDebt("gold", urn1), 0);
        assertEq(collateralBalance("gold", urn1), 7 ether);
        assertEq(cdpCore.badDebt(address(settlement)), fxp45Int(15 ether));

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(15 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(15 ether));

        // CDP closing
        ali.transferCollateralFromCDP("gold");
        assertEq(collateralBalance("gold", urn1), 0);
        assertEq(collateralToken("gold", urn1), 7 ether);
        ali.exit(gold.gemA, address(this), 7 ether);

        hevm.warp(now + 1 hours);
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        assertTrue(auctionEndTimestamp.fix("gold") != 0);

        // dai redemption
        ali.grantAccess(address(auctionEndTimestamp));
        ali.pack(15 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(15 ether));

        // global checks:
        assertEq(cdpCore.debt(), 0);
        assertEq(cdpCore.badDebtSupply(), 0);

        ali.cash("gold", 15 ether);

        // local checks:
        assertEq(dai(urn1), 0);
        assertEq(collateralToken("gold", urn1), 3 ether);
        ali.exit(gold.gemA, address(this), 3 ether);

        assertEq(collateralToken("gold", address(auctionEndTimestamp)), 0);
        assertEq(balanceOf("gold", address(gold.gemA)), 0);
    }

    // -- Scenario where there is one over-collateralised and one
    // -- under-collateralised CDP, and no Settlement deficit or surplus
    function test_cage_undercollateralised() public {
        CollateralType memory gold = init_collateral("gold");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);
        Usr bob = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // ali's cdp has 0 collateralToken, 10 collateralBalance, 15 tab, 15 dai

        // make a second CDP:
        address urn2 = address(bob);
        gold.gemA.deposit(urn2, 1 ether);
        bob.modifyCDP("gold", urn2, urn2, urn2, 1 ether, 3 ether);
        // bob's cdp has 0 collateralToken, 1 collateralBalance, 3 tab, 3 dai

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(18 ether));
        assertEq(cdpCore.badDebtSupply(), 0);

        // collateral price is 2
        gold.pip.poke(bytes32(2 * WAD));
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");
        auctionEndTimestamp.skim("gold", urn1);  // over-collateralised
        auctionEndTimestamp.skim("gold", urn2);  // under-collateralised

        // local checks
        assertEq(stablecoinDebt("gold", urn1), 0);
        assertEq(collateralBalance("gold", urn1), 2.5 ether);
        assertEq(stablecoinDebt("gold", urn2), 0);
        assertEq(collateralBalance("gold", urn2), 0);
        assertEq(cdpCore.badDebt(address(settlement)), fxp45Int(18 ether));

        // global checks
        assertEq(cdpCore.debt(), fxp45Int(18 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(18 ether));

        // CDP closing
        ali.transferCollateralFromCDP("gold");
        assertEq(collateralBalance("gold", urn1), 0);
        assertEq(collateralToken("gold", urn1), 2.5 ether);
        ali.exit(gold.gemA, address(this), 2.5 ether);

        hevm.warp(now + 1 hours);
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        assertTrue(auctionEndTimestamp.fix("gold") != 0);

        // first dai redemption
        ali.grantAccess(address(auctionEndTimestamp));
        ali.pack(15 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(15 ether));

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(3 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(3 ether));

        ali.cash("gold", 15 ether);

        // local checks:
        assertEq(dai(urn1), 0);
        uint256 fix = auctionEndTimestamp.fix("gold");
        assertEq(collateralToken("gold", urn1), rmul(fix, 15 ether));
        ali.exit(gold.gemA, address(this), rmul(fix, 15 ether));

        // second dai redemption
        bob.grantAccess(address(auctionEndTimestamp));
        bob.pack(3 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(3 ether));

        // global checks:
        assertEq(cdpCore.debt(), 0);
        assertEq(cdpCore.badDebtSupply(), 0);

        bob.cash("gold", 3 ether);

        // local checks:
        assertEq(dai(urn2), 0);
        assertEq(collateralToken("gold", urn2), rmul(fix, 3 ether));
        bob.exit(gold.gemA, address(this), rmul(fix, 3 ether));

        // some dust remains in the End because of rounding:
        assertEq(collateralToken("gold", address(auctionEndTimestamp)), 1);
        assertEq(balanceOf("gold", address(gold.gemA)), 1);
    }

    // -- Scenario where there is one collateralised CDP
    // -- undergoing auction at the time of disable
    function test_cage_skip() public {
        CollateralType memory gold = init_collateral("gold");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // this cdp has 0 collateralToken, 10 collateralBalance, 15 tab, 15 dai

        cdpCore.changeConfig("gold", "maxDaiPerUnitOfCollateral", fxp27Int(1 ether));     // now unsafe

        uint auction = cat.liquidateCdp("gold", urn1);  // CDP liquidated
        assertEq(cdpCore.badDebtSupply(), fxp45Int(15 ether));    // now there is badDebt
        // get 1 dai from ali
        ali.transfer(address(ali), address(this), fxp45Int(1 ether));
        cdpCore.grantAccess(address(gold.collateralForDaiAuction));
        (,uint lot,,,,,,) = gold.collateralForDaiAuction.bids(auction);
        gold.collateralForDaiAuction.makeBidIncreaseBidSize(auction, lot, fxp45Int(1 ether)); // bid 1 dai
        assertEq(dai(urn1), 14 ether);

        // collateral price is 5
        gold.pip.poke(bytes32(5 * WAD));
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");

        auctionEndTimestamp.skip("gold", auction);
        assertEq(dai(address(this)), 1 ether);       // bid refunded
        cdpCore.transfer(address(this), urn1, fxp45Int(1 ether)); // return 1 dai to ali

        auctionEndTimestamp.skim("gold", urn1);

        // local checks:
        assertEq(stablecoinDebt("gold", urn1), 0);
        assertEq(collateralBalance("gold", urn1), 7 ether);
        assertEq(cdpCore.badDebt(address(settlement)), fxp45Int(30 ether));

        // balance the settlement
        settlement.settleDebtUsingSurplus(min(cdpCore.dai(address(settlement)), cdpCore.badDebt(address(settlement))));
        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(15 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(15 ether));

        // CDP closing
        ali.transferCollateralFromCDP("gold");
        assertEq(collateralBalance("gold", urn1), 0);
        assertEq(collateralToken("gold", urn1), 7 ether);
        ali.exit(gold.gemA, address(this), 7 ether);

        hevm.warp(now + 1 hours);
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        assertTrue(auctionEndTimestamp.fix("gold") != 0);

        // dai redemption
        ali.grantAccess(address(auctionEndTimestamp));
        ali.pack(15 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(15 ether));

        // global checks:
        assertEq(cdpCore.debt(), 0);
        assertEq(cdpCore.badDebtSupply(), 0);

        ali.cash("gold", 15 ether);

        // local checks:
        assertEq(dai(urn1), 0);
        assertEq(collateralToken("gold", urn1), 3 ether);
        ali.exit(gold.gemA, address(this), 3 ether);

        assertEq(collateralToken("gold", address(auctionEndTimestamp)), 0);
        assertEq(balanceOf("gold", address(gold.gemA)), 0);
    }

    // -- Scenario where there is one over-collateralised CDP
    // -- and there is a deficit in the Settlement
    function test_cage_collateralised_deficit() public {
        CollateralType memory gold = init_collateral("gold");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // ali's cdp has 0 collateralToken, 10 collateralBalance, 15 tab, 15 dai
        // issueBadDebt 1 dai and give to ali
        cdpCore.issueBadDebt(address(settlement), address(ali), fxp45Int(1 ether));

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(16 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(1 ether));

        // collateral price is 5
        gold.pip.poke(bytes32(5 * WAD));
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");
        auctionEndTimestamp.skim("gold", urn1);

        // local checks:
        assertEq(stablecoinDebt("gold", urn1), 0);
        assertEq(collateralBalance("gold", urn1), 7 ether);
        assertEq(cdpCore.badDebt(address(settlement)), fxp45Int(16 ether));

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(16 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(16 ether));

        // CDP closing
        ali.transferCollateralFromCDP("gold");
        assertEq(collateralBalance("gold", urn1), 0);
        assertEq(collateralToken("gold", urn1), 7 ether);
        ali.exit(gold.gemA, address(this), 7 ether);

        hevm.warp(now + 1 hours);
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        assertTrue(auctionEndTimestamp.fix("gold") != 0);

        // dai redemption
        ali.grantAccess(address(auctionEndTimestamp));
        ali.pack(16 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(16 ether));

        // global checks:
        assertEq(cdpCore.debt(), 0);
        assertEq(cdpCore.badDebtSupply(), 0);

        ali.cash("gold", 16 ether);

        // local checks:
        assertEq(dai(urn1), 0);
        assertEq(collateralToken("gold", urn1), 3 ether);
        ali.exit(gold.gemA, address(this), 3 ether);

        assertEq(collateralToken("gold", address(auctionEndTimestamp)), 0);
        assertEq(balanceOf("gold", address(gold.gemA)), 0);
    }

    // -- Scenario where there is one over-collateralised CDP
    // -- and one under-collateralised CDP and there is a
    // -- surplus in the Settlement
    function test_cage_undercollateralised_surplus() public {
        CollateralType memory gold = init_collateral("gold");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);
        Usr bob = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // ali's cdp has 0 collateralToken, 10 collateralBalance, 15 tab, 15 dai
        // alive gives one dai to the settlement, creating surplus
        ali.transfer(address(ali), address(settlement), fxp45Int(1 ether));

        // make a second CDP:
        address urn2 = address(bob);
        gold.gemA.deposit(urn2, 1 ether);
        bob.modifyCDP("gold", urn2, urn2, urn2, 1 ether, 3 ether);
        // bob's cdp has 0 collateralToken, 1 collateralBalance, 3 tab, 3 dai

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(18 ether));
        assertEq(cdpCore.badDebtSupply(), 0);

        // collateral price is 2
        gold.pip.poke(bytes32(2 * WAD));
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");
        auctionEndTimestamp.skim("gold", urn1);  // over-collateralised
        auctionEndTimestamp.skim("gold", urn2);  // under-collateralised

        // local checks
        assertEq(stablecoinDebt("gold", urn1), 0);
        assertEq(collateralBalance("gold", urn1), 2.5 ether);
        assertEq(stablecoinDebt("gold", urn2), 0);
        assertEq(collateralBalance("gold", urn2), 0);
        assertEq(cdpCore.badDebt(address(settlement)), fxp45Int(18 ether));

        // global checks
        assertEq(cdpCore.debt(), fxp45Int(18 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(18 ether));

        // CDP closing
        ali.transferCollateralFromCDP("gold");
        assertEq(collateralBalance("gold", urn1), 0);
        assertEq(collateralToken("gold", urn1), 2.5 ether);
        ali.exit(gold.gemA, address(this), 2.5 ether);

        hevm.warp(now + 1 hours);
        // balance the settlement
        settlement.settleDebtUsingSurplus(fxp45Int(1 ether));
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        assertTrue(auctionEndTimestamp.fix("gold") != 0);

        // first dai redemption
        ali.grantAccess(address(auctionEndTimestamp));
        ali.pack(14 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(14 ether));

        // global checks:
        assertEq(cdpCore.debt(), fxp45Int(3 ether));
        assertEq(cdpCore.badDebtSupply(), fxp45Int(3 ether));

        ali.cash("gold", 14 ether);

        // local checks:
        assertEq(dai(urn1), 0);
        uint256 fix = auctionEndTimestamp.fix("gold");
        assertEq(collateralToken("gold", urn1), rmul(fix, 14 ether));
        ali.exit(gold.gemA, address(this), rmul(fix, 14 ether));

        // second dai redemption
        bob.grantAccess(address(auctionEndTimestamp));
        bob.pack(3 ether);
        settlement.settleDebtUsingSurplus(fxp45Int(3 ether));

        // global checks:
        assertEq(cdpCore.debt(), 0);
        assertEq(cdpCore.badDebtSupply(), 0);

        bob.cash("gold", 3 ether);

        // local checks:
        assertEq(dai(urn2), 0);
        assertEq(collateralToken("gold", urn2), rmul(fix, 3 ether));
        bob.exit(gold.gemA, address(this), rmul(fix, 3 ether));

        // nothing left in the End
        assertEq(collateralToken("gold", address(auctionEndTimestamp)), 0);
        assertEq(balanceOf("gold", address(gold.gemA)), 0);
    }

    // -- Scenario where there is one over-collateralised and one
    // -- under-collateralised CDP of different collateral types
    // -- and no Settlement deficit or surplus
    function test_cage_net_undercollateralised_multiple_ilks() public {
        CollateralType memory gold = init_collateral("gold");
        CollateralType memory coal = init_collateral("coal");

        Usr ali = new Usr(cdpCore, auctionEndTimestamp);
        Usr bob = new Usr(cdpCore, auctionEndTimestamp);

        // make a CDP:
        address urn1 = address(ali);
        gold.gemA.deposit(urn1, 10 ether);
        ali.modifyCDP("gold", urn1, urn1, urn1, 10 ether, 15 ether);
        // ali's cdp has 0 collateralToken, 10 collateralBalance, 15 tab

        // make a second CDP:
        address urn2 = address(bob);
        coal.gemA.deposit(urn2, 1 ether);
        cdpCore.changeConfig("coal", "maxDaiPerUnitOfCollateral", fxp27Int(5 ether));
        bob.modifyCDP("coal", urn2, urn2, urn2, 1 ether, 5 ether);
        // bob's cdp has 0 collateralToken, 1 collateralBalance, 5 tab

        gold.pip.poke(bytes32(2 * WAD));
        // urn1 has 20 dai of collateralBalance and 15 dai of tab
        coal.pip.poke(bytes32(2 * WAD));
        // urn2 has 2 dai of collateralBalance and 5 dai of tab
        auctionEndTimestamp.disable();
        auctionEndTimestamp.disable("gold");
        auctionEndTimestamp.disable("coal");
        auctionEndTimestamp.skim("gold", urn1);  // over-collateralised
        auctionEndTimestamp.skim("coal", urn2);  // under-collateralised

        hevm.warp(now + 1 hours);
        auctionEndTimestamp.thaw();
        auctionEndTimestamp.flow("gold");
        auctionEndTimestamp.flow("coal");

        ali.grantAccess(address(auctionEndTimestamp));
        bob.grantAccess(address(auctionEndTimestamp));

        assertEq(cdpCore.debt(),             fxp45Int(20 ether));
        assertEq(cdpCore.badDebtSupply(),             fxp45Int(20 ether));
        assertEq(cdpCore.badDebt(address(settlement)),  fxp45Int(20 ether));

        assertEq(auctionEndTimestamp.totalStablecoinDebt("gold"), 15 ether);
        assertEq(auctionEndTimestamp.totalStablecoinDebt("coal"),  5 ether);

        assertEq(auctionEndTimestamp.gap("gold"),  0.0 ether);
        assertEq(auctionEndTimestamp.gap("coal"),  1.5 ether);

        // there are 7.5 gold and 1 coal
        // the gold is worth 15 dai and the coal is worth 2 dai
        // the total collateral pool is worth 17 dai
        // the total outstanding debt is 20 dai
        // each dai should get (15/2)/20 gold and (2/2)/20 coal
        assertEq(auctionEndTimestamp.fix("gold"), fxp27Int(0.375 ether));
        assertEq(auctionEndTimestamp.fix("coal"), fxp27Int(0.050 ether));

        assertEq(collateralToken("gold", address(ali)), 0 ether);
        ali.pack(1 ether);
        ali.cash("gold", 1 ether);
        assertEq(collateralToken("gold", address(ali)), 0.375 ether);

        bob.pack(1 ether);
        bob.cash("coal", 1 ether);
        assertEq(collateralToken("coal", address(bob)), 0.05 ether);

        ali.exit(gold.gemA, address(ali), 0.375 ether);
        bob.exit(coal.gemA, address(bob), 0.05  ether);
        ali.pack(1 ether);
        ali.cash("gold", 1 ether);
        ali.cash("coal", 1 ether);
        assertEq(collateralToken("gold", address(ali)), 0.375 ether);
        assertEq(collateralToken("coal", address(ali)), 0.05 ether);

        ali.exit(gold.gemA, address(ali), 0.375 ether);
        ali.exit(coal.gemA, address(ali), 0.05  ether);

        ali.pack(1 ether);
        ali.cash("gold", 1 ether);
        assertEq(auctionEndTimestamp.out("gold", address(ali)), 3 ether);
        assertEq(auctionEndTimestamp.out("coal", address(ali)), 1 ether);
        ali.pack(1 ether);
        ali.cash("coal", 1 ether);
        assertEq(auctionEndTimestamp.out("gold", address(ali)), 3 ether);
        assertEq(auctionEndTimestamp.out("coal", address(ali)), 2 ether);
        assertEq(collateralToken("gold", address(ali)), 0.375 ether);
        assertEq(collateralToken("coal", address(ali)), 0.05 ether);
    }
}

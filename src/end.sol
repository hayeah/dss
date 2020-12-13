// SPDX-License-Identifier: AGPL-3.0-or-later

/// auctionEndTimestamp.sol -- global settlement engine

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

import "./lib.sol";

interface CDPCoreInterface {
    function dai(address) external view returns (uint256);
    function collateralTypes(bytes32 collateralType) external returns (
        uint256 totalStablecoinDebt,   // [fxp18Int]
        uint256 debtMultiplierIncludingStabilityFee,  // [fxp27Int]
        uint256 maxDaiPerUnitOfCollateral,  // [fxp27Int]
        uint256 debtCeiling,  // [fxp45Int]
        uint256 dust   // [fxp45Int]
    );
    function cdps(bytes32 collateralType, address cdp) external returns (
        uint256 collateralBalance,   // [fxp18Int]
        uint256 stablecoinDebt    // [fxp18Int]
    );
    function debt() external returns (uint256);
    function transfer(address src, address dst, uint256 fxp45Int) external;
    function grantAccess(address) external;
    function transferCollateral(bytes32 collateralType, address src, address dst, uint256 fxp45Int) external;
    function liquidateCDP(bytes32 i, address u, address v, address w, int256 changeInCollateral, int256 changeInDebt) external;
    function issueBadDebt(address u, address v, uint256 fxp45Int) external;
    function disable() external;
}
interface CatLike {
    function collateralTypes(bytes32) external returns (
        address collateralForDaiAuction,
        uint256 liquidationPenalty,  // [fxp27Int]
        uint256 liquidationQuantity   // [fxp45Int]
    );
    function disable() external;
}
interface PotLike {
    function disable() external;
}
interface SettlementInterface {
    function disable() external;
}
interface Flippy {
    function bids(uint id) external view returns (
        uint256 bid,   // [fxp45Int]
        uint256 lot,   // [fxp18Int]
        address highBidder,
        uint48  bidExpiry,   // [unix epoch time]
        uint48  auctionEndTimestamp,   // [unix epoch time]
        address usr,
        address incomeRecipient,
        uint256 tab    // [fxp45Int]
    );
    function closeBid(uint id) external;
}

interface PipLike {
    function read() external view returns (bytes32);
}

interface Spotty {
    function par() external view returns (uint256);
    function collateralTypes(bytes32) external view returns (
        PipLike pip,
        uint256 mat    // [fxp27Int]
    );
    function disable() external;
}

/*
    This is the `End` and it coordinates Global Settlement. This is an
    involved, stateful process that takes place over nine steps.

    First we freeze the system and transferCollateralToCDP the prices for each collateralType.

    1. `disable()`:
        - freezes user entrypoints
        - cancels flop/flap auctions
        - starts cooldown period
        - stops pot drips

    2. `disable(collateralType)`:
       - set the disable price for each `collateralType`, reading off the price feed

    We must process some system state before it is possible to calculate
    the final dai / collateral price. In particular, we need to determine

      a. `gap`, the collateral shortfall per collateral type by
         considering under-collateralised CDPs.

      b. `debt`, the outstanding dai supply after including system
         surplus / deficit

    We determine (a) by processing all under-collateralised CDPs with
    `skim`:

    3. `skim(collateralType, cdp)`:
       - cancels CDP debt
       - any excess collateral remains
       - backing collateral taken

    We determine (b) by processing ongoing dai generating processes,
    i.e. auctions. We need to ensure that auctions will not generate any
    further dai income. In the two-way auction model this occurs when
    all auctions are in the reverse (`makeBidDecreaseLotSize`) phase. There are two ways
    of ensuring this:

    4.  i) `debtQueueLength`: set the cooldown period to be at least as long as the
           longest auction duration, which needs to be determined by the
           disable administrator.

           This takes a fairly predictable time to occur but with altered
           auction dynamics due to the now varying price of dai.

       ii) `skip`: cancel all ongoing auctions and seize the collateral.

           This allows for faster processing at the expense of more
           processing calls. This option allows dai holders to retrieve
           their collateral faster.

           `skip(collateralType, id)`:
            - cancel individual collateralForDaiAuction auctions in the `makeBidIncreaseBidSize` (forward) phase
            - retrieves collateral and returns dai to bidder
            - `makeBidDecreaseLotSize` (reverse) phase auctions can continue normally

    Option (i), `debtQueueLength`, is sufficient for processing the system
    settlement but option (ii), `skip`, will speed it up. Both options
    are available in this implementation, with `skip` being enabled on a
    per-auction basis.

    When a CDP has been processed and has no debt remaining, the
    remaining collateral can be removed.

    5. `transferCollateralFromCDP(collateralType)`:
        - remove collateral from the caller's CDP
        - owner can call as needed

    After the processing period has elapsed, we enable calculation of
    the final price for each collateral type.

    6. `thaw()`:
       - only callable after processing time period elapsed
       - assumption that all under-collateralised CDPs are processed
       - fixes the total outstanding supply of dai
       - may also require extra CDP processing to cover settlement surplus

    7. `flow(collateralType)`:
        - calculate the `fix`, the cash price for a given collateralType
        - adjusts the `fix` in the case of deficit / surplus

    At this point we have computed the final price for each collateral
    type and dai holders can now turn their dai into collateral. Each
    unit dai can claim a fixed basket of collateral.

    Dai holders must first `pack` some dai into a `bag`. Once packed,
    dai cannot be unpacked and is not transferrable. More dai can be
    added to a bag later.

    8. `pack(fxp18Int)`:
        - put some dai into a bag in preparation for `cash`

    Finally, collateral can be obtained with `cash`. The bigger the bag,
    the more collateral can be released.

    9. `cash(collateralType, fxp18Int)`:
        - exchange some dai from your bag for collateralTokens from a specific collateralType
        - the number of collateralTokens is limited by how big your bag is
*/

contract End is LibNote {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 1; }
    function deauthorizeAddress(address highBidder) external note isAuthorized { auths[highBidder] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "End/not-authorized");
        _;
    }

    // --- Data ---
    CDPCoreInterface  public cdpCore;   // CDP Engine
    CatLike  public cat;
    SettlementInterface  public settlement;   // Debt Engine
    PotLike  public pot;
    Spotty   public maxDaiPerUnitOfCollateral;

    uint256  public isAlive;  // Active Flag
    uint256  public when;  // Time of disable                   [unix epoch time]
    uint256  public debtQueueLength;  // Processing Cooldown Length             [seconds]
    uint256  public debt;  // Total outstanding dai following processing [fxp45Int]

    mapping (bytes32 => uint256) public tag;  // Cage price              [fxp27Int]
    mapping (bytes32 => uint256) public gap;  // Collateral shortfall    [fxp18Int]
    mapping (bytes32 => uint256) public totalStablecoinDebt;  // Total debt per collateralType      [fxp18Int]
    mapping (bytes32 => uint256) public fix;  // Final cash price        [fxp27Int]

    mapping (address => uint256)                      public bag;  //    [fxp18Int]
    mapping (bytes32 => mapping (address => uint256)) public out;  //    [fxp18Int]

    // --- Init ---
    constructor() public {
        auths[msg.sender] = 1;
        isAlive = 1;
    }

    // --- Math ---
    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function min(uint x, uint y) internal pure returns (uint z) {
        return x <= y ? x : y;
    }
    uint constant WAD = 10 ** 18;
    uint constant RAY = 10 ** 27;
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, RAY) / y;
    }
    function wdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, WAD) / y;
    }

    // --- Administration ---
    function changeConfig(bytes32 what, address data) external note isAuthorized {
        require(isAlive == 1, "End/not-isAlive");
        if (what == "cdpCore")  cdpCore = CDPCoreInterface(data);
        else if (what == "cat")  cat = CatLike(data);
        else if (what == "settlement")  settlement = SettlementInterface(data);
        else if (what == "pot")  pot = PotLike(data);
        else if (what == "maxDaiPerUnitOfCollateral") maxDaiPerUnitOfCollateral = Spotty(data);
        else revert("End/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 what, uint256 data) external note isAuthorized {
        require(isAlive == 1, "End/not-isAlive");
        if (what == "debtQueueLength") debtQueueLength = data;
        else revert("End/changeConfig-unrecognized-param");
    }

    // --- Settlement ---
    function disable() external note isAuthorized {
        require(isAlive == 1, "End/not-isAlive");
        isAlive = 0;
        when = now;
        cdpCore.disable();
        cat.disable();
        settlement.disable();
        maxDaiPerUnitOfCollateral.disable();
        pot.disable();
    }

    function disable(bytes32 collateralType) external note {
        require(isAlive == 0, "End/still-isAlive");
        require(tag[collateralType] == 0, "End/tag-collateralType-already-defined");
        (totalStablecoinDebt[collateralType],,,,) = cdpCore.collateralTypes(collateralType);
        (PipLike pip,) = maxDaiPerUnitOfCollateral.collateralTypes(collateralType);
        // par is a fxp27Int, pip returns a fxp18Int
        tag[collateralType] = wdiv(maxDaiPerUnitOfCollateral.par(), uint(pip.read()));
    }

    function skip(bytes32 collateralType, uint256 id) external note {
        require(tag[collateralType] != 0, "End/tag-collateralType-not-defined");

        (address flipV,,) = cat.collateralTypes(collateralType);
        Flippy collateralForDaiAuction = Flippy(flipV);
        (, uint debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes(collateralType);
        (uint bid, uint lot,,,, address usr,, uint tab) = collateralForDaiAuction.bids(id);

        cdpCore.issueBadDebt(address(settlement), address(settlement),  tab);
        cdpCore.issueBadDebt(address(settlement), address(this), bid);
        cdpCore.grantAccess(address(collateralForDaiAuction));
        collateralForDaiAuction.closeBid(id);

        uint stablecoinDebt = tab / debtMultiplierIncludingStabilityFee;
        totalStablecoinDebt[collateralType] = add(totalStablecoinDebt[collateralType], stablecoinDebt);
        require(int(lot) >= 0 && int(stablecoinDebt) >= 0, "End/overflow");
        cdpCore.liquidateCDP(collateralType, usr, address(this), address(settlement), int(lot), int(stablecoinDebt));
    }

    function skim(bytes32 collateralType, address cdp) external note {
        require(tag[collateralType] != 0, "End/tag-collateralType-not-defined");
        (, uint debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes(collateralType);
        (uint collateralBalance, uint stablecoinDebt) = cdpCore.cdps(collateralType, cdp);

        uint owe = rmul(rmul(stablecoinDebt, debtMultiplierIncludingStabilityFee), tag[collateralType]);
        uint fxp18Int = min(collateralBalance, owe);
        gap[collateralType] = add(gap[collateralType], sub(owe, fxp18Int));

        require(fxp18Int <= 2**255 && stablecoinDebt <= 2**255, "End/overflow");
        cdpCore.liquidateCDP(collateralType, cdp, address(this), address(settlement), -int(fxp18Int), -int(stablecoinDebt));
    }

    function transferCollateralFromCDP(bytes32 collateralType) external note {
        require(isAlive == 0, "End/still-isAlive");
        (uint collateralBalance, uint stablecoinDebt) = cdpCore.cdps(collateralType, msg.sender);
        require(stablecoinDebt == 0, "End/stablecoinDebt-not-zero");
        require(collateralBalance <= 2**255, "End/overflow");
        cdpCore.liquidateCDP(collateralType, msg.sender, msg.sender, address(settlement), -int(collateralBalance), 0);
    }

    function thaw() external note {
        require(isAlive == 0, "End/still-isAlive");
        require(debt == 0, "End/debt-not-zero");
        require(cdpCore.dai(address(settlement)) == 0, "End/surplus-not-zero");
        require(now >= add(when, debtQueueLength), "End/debtQueueLength-not-finished");
        debt = cdpCore.debt();
    }
    function flow(bytes32 collateralType) external note {
        require(debt != 0, "End/debt-zero");
        require(fix[collateralType] == 0, "End/fix-collateralType-already-defined");

        (, uint debtMultiplierIncludingStabilityFee,,,) = cdpCore.collateralTypes(collateralType);
        uint256 fxp18Int = rmul(rmul(totalStablecoinDebt[collateralType], debtMultiplierIncludingStabilityFee), tag[collateralType]);
        fix[collateralType] = rdiv(mul(sub(fxp18Int, gap[collateralType]), RAY), debt);
    }

    function pack(uint256 fxp18Int) external note {
        require(debt != 0, "End/debt-zero");
        cdpCore.transfer(msg.sender, address(settlement), mul(fxp18Int, RAY));
        bag[msg.sender] = add(bag[msg.sender], fxp18Int);
    }
    function cash(bytes32 collateralType, uint fxp18Int) external note {
        require(fix[collateralType] != 0, "End/fix-collateralType-not-defined");
        cdpCore.transferCollateral(collateralType, address(this), msg.sender, rmul(fxp18Int, fix[collateralType]));
        out[collateralType][msg.sender] = add(out[collateralType][msg.sender], fxp18Int);
        require(out[collateralType][msg.sender] <= bag[msg.sender], "End/insufficient-bag-balance");
    }
}

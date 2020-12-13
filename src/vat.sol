// SPDX-License-Identifier: AGPL-3.0-or-later

/// cdpCore.sol -- Dai CDP database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
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

contract CDPCore {
    // --- Auth ---
    mapping (address => uint) public auths;
    function authorizeAddress(address usr) external note isAuthorized { require(isAlive == 1, "CDPCore/not-isAlive"); auths[usr] = 1; }
    function deauthorizeAddress(address usr) external note isAuthorized { require(isAlive == 1, "CDPCore/not-isAlive"); auths[usr] = 0; }
    modifier isAuthorized {
        require(auths[msg.sender] == 1, "CDPCore/not-authorized");
        _;
    }

    mapping(address => mapping (address => uint)) public can;
    function grantAccess(address usr) external note { can[msg.sender][usr] = 1; }
    function revokeAccess(address usr) external note { can[msg.sender][usr] = 0; }
    function hasAccess(address bit, address usr) internal view returns (bool) {
        return boolOr(bit == usr, can[bit][usr] == 1);
    }

    // --- Data ---
    struct CollateralType {
        uint256 totalStablecoinDebt;   // Total Normalised Debt     [fxp18Int]
        uint256 debtMultiplierIncludingStabilityFee;  // Accumulated Rates         [fxp27Int]
        uint256 maxDaiPerUnitOfCollateral;  // Price with Safety Margin  [fxp27Int]
        uint256 debtCeiling;  // Debt Ceiling              [fxp45Int]
        uint256 dust;  // CDP Debt Floor            [fxp45Int]
    }
    struct CDP {
        uint256 collateralBalance;   // Locked Collateral  [fxp18Int]
        uint256 stablecoinDebt;   // Normalised Debt    [fxp18Int]
    }

    mapping (bytes32 => CollateralType)                       public collateralTypes;
    mapping (bytes32 => mapping (address => CDP )) public cdps;
    mapping (bytes32 => mapping (address => uint)) public collateralToken;  // [fxp18Int]
    mapping (address => uint256)                   public dai;  // [fxp45Int]
    mapping (address => uint256)                   public badDebt;  // [fxp45Int]

    uint256 public debt;  // Total Dai Issued    [fxp45Int]
    uint256 public badDebtSupply;  // Total Unbacked Dai  [fxp45Int]
    uint256 public totalDebtCeiling;  // Total Debt Ceiling  [fxp45Int]
    uint256 public isAlive;  // Active Flag

    // --- Logs ---
    event LogNote(
        bytes4   indexed  sig,
        bytes32  indexed  arg1,
        bytes32  indexed  arg2,
        bytes32  indexed  arg3,
        bytes             data
    ) anonymous;

    modifier note {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: the selector and the first three args
            let mark := msize()                       // auctionEndTimestamp of memory ensures zero
            mstore(0x40, add(mark, 288))              // update transferCollateralFromCDP memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 calldataload(4),                     // arg1
                 calldataload(36),                    // arg2
                 calldataload(68)                     // arg3
                )
        }
    }

    // --- Init ---
    constructor() public {
        auths[msg.sender] = 1;
        isAlive = 1;
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function createNewCollateralType(bytes32 collateralType) external note isAuthorized {
        require(collateralTypes[collateralType].debtMultiplierIncludingStabilityFee == 0, "CDPCore/collateralType-already-createNewCollateralType");
        collateralTypes[collateralType].debtMultiplierIncludingStabilityFee = 10 ** 27;
    }
    function changeConfig(bytes32 what, uint data) external note isAuthorized {
        require(isAlive == 1, "CDPCore/not-isAlive");
        if (what == "totalDebtCeiling") totalDebtCeiling = data;
        else revert("CDPCore/changeConfig-unrecognized-param");
    }
    function changeConfig(bytes32 collateralType, bytes32 what, uint data) external note isAuthorized {
        require(isAlive == 1, "CDPCore/not-isAlive");
        if (what == "maxDaiPerUnitOfCollateral") collateralTypes[collateralType].maxDaiPerUnitOfCollateral = data;
        else if (what == "debtCeiling") collateralTypes[collateralType].debtCeiling = data;
        else if (what == "dust") collateralTypes[collateralType].dust = data;
        else revert("CDPCore/changeConfig-unrecognized-param");
    }
    function disable() external note isAuthorized {
        isAlive = 0;
    }

    // --- Fungibility ---
    function modifyUsersCollateralBalance(bytes32 collateralType, address usr, int256 fxp18Int) external note isAuthorized {
        collateralToken[collateralType][usr] = add(collateralToken[collateralType][usr], fxp18Int);
    }
    function transferCollateral(bytes32 collateralType, address src, address dst, uint256 fxp18Int) external note {
        require(hasAccess(src, msg.sender), "CDPCore/not-allowed");
        collateralToken[collateralType][src] = sub(collateralToken[collateralType][src], fxp18Int);
        collateralToken[collateralType][dst] = add(collateralToken[collateralType][dst], fxp18Int);
    }
    function transfer(address src, address dst, uint256 fxp45Int) external note {
        require(hasAccess(src, msg.sender), "CDPCore/not-allowed");
        dai[src] = sub(dai[src], fxp45Int);
        dai[dst] = add(dai[dst], fxp45Int);
    }

    function boolOr(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function boolAnd(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    function modifyCDP(bytes32 i, address u, address v, address w, int changeInCollateral, int changeInDebt) external note {
        // system is isAlive
        require(isAlive == 1, "CDPCore/not-isAlive");

        CDP memory cdp = cdps[i][u];
        CollateralType memory collateralType = collateralTypes[i];
        // collateralType has been initialised
        require(collateralType.debtMultiplierIncludingStabilityFee != 0, "CDPCore/collateralType-not-createNewCollateralType");

        cdp.collateralBalance = add(cdp.collateralBalance, changeInCollateral);
        cdp.stablecoinDebt = add(cdp.stablecoinDebt, changeInDebt);
        collateralType.totalStablecoinDebt = add(collateralType.totalStablecoinDebt, changeInDebt);

        int penalty = mul(collateralType.debtMultiplierIncludingStabilityFee, changeInDebt);
        uint tab = mul(collateralType.debtMultiplierIncludingStabilityFee, cdp.stablecoinDebt);
        debt     = add(debt, penalty);

        // either debt has decreased, or debt ceilings are not exceeded
        require(boolOr(changeInDebt <= 0, boolAnd(mul(collateralType.totalStablecoinDebt, collateralType.debtMultiplierIncludingStabilityFee) <= collateralType.debtCeiling, debt <= totalDebtCeiling)), "CDPCore/ceiling-exceeded");
        // cdp is either less risky than before, or it is isCdpSafe
        require(boolOr(boolAnd(changeInDebt <= 0, changeInCollateral >= 0), tab <= mul(cdp.collateralBalance, collateralType.maxDaiPerUnitOfCollateral)), "CDPCore/not-isCdpSafe");

        // cdp is either more isCdpSafe, or the owner consents
        require(boolOr(boolAnd(changeInDebt <= 0, changeInCollateral >= 0), hasAccess(u, msg.sender)), "CDPCore/not-allowed-u");
        // collateral src consents
        require(boolOr(changeInCollateral <= 0, hasAccess(v, msg.sender)), "CDPCore/not-allowed-v");
        // debt dst consents
        require(boolOr(changeInDebt >= 0, hasAccess(w, msg.sender)), "CDPCore/not-allowed-w");

        // cdp has no debt, or a non-dusty amount
        require(boolOr(cdp.stablecoinDebt == 0, tab >= collateralType.dust), "CDPCore/dust");

        collateralToken[i][v] = sub(collateralToken[i][v], changeInCollateral);
        dai[w]    = add(dai[w],    penalty);

        cdps[i][u] = cdp;
        collateralTypes[i]    = collateralType;
    }
    // --- CDP Fungibility ---
    function transferCDP(bytes32 collateralType, address src, address dst, int changeInCollateral, int changeInDebt) external note {
        CDP storage u = cdps[collateralType][src];
        CDP storage v = cdps[collateralType][dst];
        CollateralType storage i = collateralTypes[collateralType];

        u.collateralBalance = sub(u.collateralBalance, changeInCollateral);
        u.stablecoinDebt = sub(u.stablecoinDebt, changeInDebt);
        v.collateralBalance = add(v.collateralBalance, changeInCollateral);
        v.stablecoinDebt = add(v.stablecoinDebt, changeInDebt);

        uint utab = mul(u.stablecoinDebt, i.debtMultiplierIncludingStabilityFee);
        uint vtab = mul(v.stablecoinDebt, i.debtMultiplierIncludingStabilityFee);

        // both sides consent
        require(boolAnd(hasAccess(src, msg.sender), hasAccess(dst, msg.sender)), "CDPCore/not-allowed");

        // both sides isCdpSafe
        require(utab <= mul(u.collateralBalance, i.maxDaiPerUnitOfCollateral), "CDPCore/not-isCdpSafe-src");
        require(vtab <= mul(v.collateralBalance, i.maxDaiPerUnitOfCollateral), "CDPCore/not-isCdpSafe-dst");

        // both sides non-dusty
        require(boolOr(utab >= i.dust, u.stablecoinDebt == 0), "CDPCore/dust-src");
        require(boolOr(vtab >= i.dust, v.stablecoinDebt == 0), "CDPCore/dust-dst");
    }
    // --- CDP Confiscation ---
    function liquidateCDP(bytes32 i, address u, address v, address w, int changeInCollateral, int changeInDebt) external note isAuthorized {
        CDP storage cdp = cdps[i][u];
        CollateralType storage collateralType = collateralTypes[i];

        cdp.collateralBalance = add(cdp.collateralBalance, changeInCollateral);
        cdp.stablecoinDebt = add(cdp.stablecoinDebt, changeInDebt);
        collateralType.totalStablecoinDebt = add(collateralType.totalStablecoinDebt, changeInDebt);

        int penalty = mul(collateralType.debtMultiplierIncludingStabilityFee, changeInDebt);

        collateralToken[i][v] = sub(collateralToken[i][v], changeInCollateral);
        badDebt[w]    = sub(badDebt[w],    penalty);
        badDebtSupply      = sub(badDebtSupply,      penalty);
    }

    // --- Settlement ---
    function settleDebtUsingSurplus(uint fxp45Int) external note {
        address u = msg.sender;
        badDebt[u] = sub(badDebt[u], fxp45Int);
        dai[u] = sub(dai[u], fxp45Int);
        badDebtSupply   = sub(badDebtSupply,   fxp45Int);
        debt   = sub(debt,   fxp45Int);
    }
    function issueBadDebt(address u, address v, uint fxp45Int) external note isAuthorized {
        badDebt[u] = add(badDebt[u], fxp45Int);
        dai[v] = add(dai[v], fxp45Int);
        badDebtSupply   = add(badDebtSupply,   fxp45Int);
        debt   = add(debt,   fxp45Int);
    }

    // --- Rates ---
    function changeDebtMultiplier(bytes32 i, address u, int debtMultiplierIncludingStabilityFee) external note isAuthorized {
        require(isAlive == 1, "CDPCore/not-isAlive");
        CollateralType storage collateralType = collateralTypes[i];
        collateralType.debtMultiplierIncludingStabilityFee = add(collateralType.debtMultiplierIncludingStabilityFee, debtMultiplierIncludingStabilityFee);
        int fxp45Int  = mul(collateralType.totalStablecoinDebt, debtMultiplierIncludingStabilityFee);
        dai[u]   = add(dai[u], fxp45Int);
        debt     = add(debt,   fxp45Int);
    }
}

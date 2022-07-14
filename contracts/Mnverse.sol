// "SPDX-License-Identifier: UNLICENSED"

pragma experimental ABIEncoderV2;
pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./Mnland.sol";

contract Mnverse is AccessControlEnumerable, ERC721Holder, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Counters for Counters.Counter;

    event BuyLand(
        address indexed buyer,
        uint256 indexed tokenId,
        address token,
        uint256 price,
        string[] points
    );

    event BuyLandFrom(
        address indexed buyer,
        address indexed seller,
        uint256 indexed tokenId,
        address token,
        uint256 price
    );

    event SellLand(
        address indexed seller,
        uint256 indexed landId,
        uint256 indexed tokenId,
        address token,
        uint256 price
    );

    event CancelSellLand(
        address indexed seller,
        uint256 indexed landId,
        uint256 indexed tokenId
    );

    event OfferToBuyLandFrom(
        address indexed buyer,
        uint256 indexed tokenId,
        address token,
        uint256 price
    );

    modifier onlyAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Caller is not an admin"
        );
        _;
    }

    modifier onlyManager() {
        require(hasRole(MANAGER_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    struct LandItem {
        address seller;
        uint256 tokenId;
        uint256 price;
        address token;
        bool active;
    }

    struct Offer {
        address buyer;
        uint256 price;
    }

    uint256 constant FEE_PERCENT_PRECISION = 1e18; // 1%
    uint256 public tradingFeePercent;
    uint256 public pointsPerTx;

    Mnland public land;
    address public busd;
    address public mn;
    address public collector;
    Counters.Counter private _landIdTracker;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    bool usestable;

    // land id => land item
    mapping(uint256 => LandItem) public landItems;

    // token id => is selling?
    mapping(uint256 => bool) public selling;

    // token id => land id
    mapping(uint256 => uint256) public landIds;

    // token id => offer
    mapping(uint256 => Offer) public bestOffer;

    // token address => price
    mapping(address => uint256) public pricePerPoint;

    // token address => price Premium
    mapping(address => uint256) public pricePerPointPremium;

    // token address => price daimond
    mapping(address => uint256) public pricePerPointDaimond;

    constructor(
        address _admin,
        Mnland _land,
        address _busd,
        address _mn,
        address _collector
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(MANAGER_ROLE, _admin);
        usestable = true;
        land = _land;
        busd = _busd;
        mn = _mn;
        pricePerPoint[_busd] = 3e18; // 3 tokens;
        pricePerPoint[_mn] = 300e18; // 300 tokens;
        pricePerPointPremium[_busd] = 4e18; // 4 tokens;
        pricePerPointPremium[_mn] = 400e18; // 400 tokens;
        pricePerPointPremium[_busd] = 4e18; // 4 tokens;
        pricePerPointDaimond[_mn] = 4e18; // 400 tokens;
        pricePerPointDaimond[_busd] = 400e18; // 400 tokens;
        collector = _collector;
        tradingFeePercent = 2e18; // 2%
        pointsPerTx = 50; // unlimited
    }

    function buyLand(string[] calldata points, address token)
        external
        whenNotPaused
    {
        require(points.length > 0, "invalid points");
        require((usestable == true && token == busd) || token == mn, "unsupport token");
        require(
            pointsPerTx == 0 || pointsPerTx >= points.length,
            "too many points"
        );

        uint256 rcount = 0;
        uint256 pcount = 0;
        uint256 dcount = 0;
        for (uint256 i; i< points.length; i++) {
          if (bytes(points[i])[3]=='r'){
            rcount++;
          }
          if (bytes(points[i])[3]=='p'){
            pcount++;
          }
          if (bytes(points[i])[3]=='d'){
            dcount++;
          }
        }
        require(rcount > 0 || pcount > 0 || dcount > 0, "invalid points data");
        uint256 rprice = pricePerPoint[token].mul(rcount);
        uint256 pprice = pricePerPointPremium[token].mul(pcount);
        uint256 dprice = pricePerPointDaimond[token].mul(dcount);
        IERC20(token).safeTransferFrom(msg.sender, collector, rprice + pprice + dprice);

        uint256 tokenId = land.mint(msg.sender, points);
        emit BuyLand(msg.sender, tokenId, token, rprice + pprice + dprice, points);
    }

    function sellLand(
        uint256 tokenId,
        address token,
        uint256 price
    ) external {
        require(land.ownerOf(tokenId) == msg.sender, "permission denied");
        require(price > 0, "invalid price");
        require(!selling[tokenId], "selling");
        require(token != address(0));

        uint256 landId = _landIdTracker.current();
        landItems[landId] = LandItem(msg.sender, tokenId, price, token, true);
        _landIdTracker.increment();
        landIds[tokenId] = landId;
        selling[tokenId] = true;

        land.safeTransferFrom(msg.sender, address(this), tokenId);

        emit SellLand(msg.sender, landId, tokenId, token, price);
    }

    function cancelSellLand(uint256 tokenId) external {
        require(selling[tokenId], "not selling");
        uint256 landId = landIds[tokenId];
        LandItem storage landItem = landItems[landId];
        require(landItem.seller == msg.sender, "permission denied");
        selling[tokenId] = false;
        landItem.active = false;

        land.safeTransferFrom(address(this), msg.sender, tokenId);

        Offer memory offer = bestOffer[tokenId];
        if (offer.buyer != address(0)) {
            IERC20(landItem.token).safeTransfer(offer.buyer, offer.price);
        }
        bestOffer[tokenId] = Offer(address(0), 0);

        emit CancelSellLand(msg.sender, landId, tokenId);
    }

    function buyLandFrom(uint256 tokenId) external {
        require(selling[tokenId], "not selling");
        uint256 landId = landIds[tokenId];
        LandItem storage landItem = landItems[landId];
        selling[tokenId] = false;
        landItem.active = false;

        uint256 feeAmount = landItem.price.mul(tradingFeePercent).div(
            FEE_PERCENT_PRECISION.mul(100)
        );
        IERC20(landItem.token).safeTransferFrom(
            msg.sender,
            landItem.seller,
            landItem.price.sub(feeAmount)
        );
        IERC20(landItem.token).safeTransferFrom(
            msg.sender,
            collector,
            feeAmount
        );
        land.safeTransferFrom(address(this), msg.sender, tokenId);

        emit BuyLandFrom(
            msg.sender,
            landItem.seller,
            tokenId,
            landItem.token,
            landItem.price
        );
    }

    function offerToBuyLandFrom(uint256 tokenId, uint256 price) external {
        require(selling[tokenId], "not selling");
        uint256 landId = landIds[tokenId];
        LandItem storage landItem = landItems[landId];
        require(price < landItem.price, "offer price too high");

        Offer memory preOffer = bestOffer[tokenId];
        require(preOffer.price < price, "offer price too low");

        if (preOffer.buyer != address(0)) {
            IERC20(landItem.token).safeTransfer(preOffer.buyer, preOffer.price);
        }

        IERC20(landItem.token).safeTransferFrom(
            msg.sender,
            address(this),
            price
        );
        bestOffer[tokenId] = Offer(msg.sender, price);

        emit OfferToBuyLandFrom(msg.sender, tokenId, landItem.token, price);
    }

    function sellLandToBestOffer(uint256 tokenId) external {
        require(selling[tokenId], "not selling");
        uint256 landId = landIds[tokenId];
        LandItem storage landItem = landItems[landId];
        require(landItem.seller == msg.sender, "permission denied");
        Offer memory offer = bestOffer[tokenId];
        require(offer.buyer != address(0) && offer.price > 0, "no offer");

        selling[tokenId] = false;
        landItem.active = false;

        uint256 feeAmount = offer.price.mul(tradingFeePercent).div(
            FEE_PERCENT_PRECISION.mul(100)
        );
        IERC20(landItem.token).safeTransfer(
            msg.sender,
            offer.price.sub(feeAmount)
        );
        IERC20(landItem.token).safeTransfer(collector, feeAmount);

        land.safeTransferFrom(address(this), offer.buyer, tokenId);

        emit BuyLandFrom(
            offer.buyer,
            msg.sender,
            tokenId,
            landItem.token,
            offer.price
        );
    }

    function currentLandId() external view returns (uint256) {
        return _landIdTracker.current();
    }

    function pause() external onlyManager whenNotPaused {
        _pause();
    }

    function unpause() external onlyManager whenPaused {
        _unpause();
    }

    function setTradingFeePercent(uint256 _tradingFeePercent)
        external
        onlyAdmin
    {
        require(_tradingFeePercent < 100e18, "fee too high");
        require(_tradingFeePercent != tradingFeePercent, "same value");
        tradingFeePercent = _tradingFeePercent;
    }

    function setPointsPerTx(uint256 _pointsPerTx) external onlyAdmin {
        require(_pointsPerTx != pointsPerTx, "same value");
        pointsPerTx = _pointsPerTx;
    }

    function setPricePerPoint(uint256 _pricePerPoint, address _token)
        external
        onlyAdmin
    {
        require(_pricePerPoint > 0e18, "fee too low");
        require(_token == busd || _token == mn, "unsupport token");
        if (_token == mn) {
          require(_pricePerPoint != pricePerPoint[mn], "same value");
          pricePerPoint[mn] = _pricePerPoint;
        }
        if (_token == busd) {
          require(_pricePerPoint != pricePerPoint[busd], "same value");
          pricePerPoint[busd] = _pricePerPoint;
        }
    }

    function setPricePerPointPremium(uint256 _pricePerPointPremium, address _token)
        external
        onlyAdmin
    {
        require(_pricePerPointPremium > 0e18, "fee too low");
        require(_token == busd || _token == mn, "unsupport token");
        if (_token == mn) {
          require(_pricePerPointPremium != pricePerPointPremium[mn], "same value");
          pricePerPointPremium[mn] = _pricePerPointPremium;
        }
        if (_token == busd) {
          require(_pricePerPointPremium != pricePerPointPremium[busd], "same value");
          pricePerPointPremium[busd] = _pricePerPointPremium;
        }
    }

    function setPricePerPointDaimond(uint256 _pricePerPointDaimond, address _token)
        external
        onlyAdmin
    {
        require(_pricePerPointDaimond > 0e18, "fee too low");
        require(_token == busd || _token == mn, "unsupport token");
        if (_token == mn) {
          require(_pricePerPointDaimond != pricePerPointDaimond[mn], "same value");
          pricePerPointDaimond[mn] = _pricePerPointDaimond;
        }
        if (_token == busd) {
          require(_pricePerPointDaimond != pricePerPointDaimond[busd], "same value");
          pricePerPointDaimond[busd] = _pricePerPointDaimond;
        }
    }

    function setAllowStable(bool _allowstable) external onlyAdmin {
        usestable = _allowstable;
    }
}

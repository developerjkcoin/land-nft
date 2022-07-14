// "SPDX-License-Identifier: UNLICENSED"

pragma experimental ABIEncoderV2;
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Mnland is ERC721Enumerable, ERC721Burnable, ERC721URIStorage,
    AccessControlEnumerable
{
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    event Merge(
        uint256 indexed tokenId1,
        uint256 indexed tokenId2,
        uint256 indexed newTokenId
    );

    event Split(
        uint256 indexed tokenId,
        uint256 indexed newTokenId
    );

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    Counters.Counter private _tokenIdTracker;

    // token id => [point_id]
    mapping(uint256 => bytes32[]) private tokenInfo;

    // point id => wallet address
    mapping(string => address) public pointOwner;

    // point id => token id
    mapping(string => uint256) public pointAllocation;

    modifier onlyMinter {
        require(hasRole(MINTER_ROLE, msg.sender), "Caller is not a minter");
        _;
    }

    modifier onlyAdmin {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    constructor() ERC721("MNLand NFT", "MNLAND") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, msg.sender);
        _tokenIdTracker.increment(); // token id: start at 1
    }

    function stringToBytes32(string memory source)
        internal pure returns (bytes32 result)
    {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }
        assembly {
            result := mload(add(source, 32))
        }
    }

    function bytes32ToString(bytes32 _bytes32)
        internal pure returns (string memory)
    {
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }

    function getPoints(uint256 tokenId)
        public view returns (string[] memory)
    {
        string[] memory _points = new string[](tokenInfo[tokenId].length);
        for (uint256 i; i < tokenInfo[tokenId].length; i++) {
            _points[i] = bytes32ToString(tokenInfo[tokenId][i]);
        }
        return _points;
    }

    function mint(address to, string[] calldata points)
        external onlyMinter returns (uint256)
    {
        require(points.length > 0, "invalid points");
        uint256 newItemId = _tokenIdTracker.current();
        _mint(to, newItemId);
        for (uint256 i; i< points.length; i++) {
            require(pointOwner[points[i]] == address(0), "duplicated point");
            tokenInfo[newItemId].push(stringToBytes32(points[i]));
            pointOwner[points[i]] = to;
            pointAllocation[points[i]] = newItemId;
        }
        _tokenIdTracker.increment();
        return newItemId;
    }

    function compareStrings(string memory a, string memory b)
        internal pure returns (bool)
    {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    function split(uint256 tokenId, string[] calldata points)
        external returns (uint256)
    {
        require(ownerOf(tokenId) == msg.sender, "permission denied");
        string[] memory oldPoints = getPoints(tokenId);
        require(points.length > 0 && oldPoints.length > points.length, "invalid points");

        bytes32[] memory newPoints = new bytes32[](oldPoints.length.sub(points.length));
        uint256 index;
        for (uint256 i=0; i<oldPoints.length; i++) {
            bool found = false;
            for (uint256 j=0; j<points.length; j++) {
                require(pointAllocation[points[j]] == tokenId, "invalid points");
                if (compareStrings(oldPoints[i], points[j])) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                newPoints[index] = stringToBytes32(oldPoints[i]);
                index += 1;
            }
        }
        tokenInfo[tokenId] = newPoints;

        uint256 newItemId = _tokenIdTracker.current();
        for (uint256 i=0; i< points.length; i++) {
            tokenInfo[newItemId].push(stringToBytes32(points[i]));
            pointAllocation[points[i]] = newItemId;
        }

        _mint(msg.sender, newItemId);
        _tokenIdTracker.increment();

        emit Split(tokenId, newItemId);

        return newItemId;
    }

    function merge(uint256 tokenId1, uint256 tokenId2)
        external returns (uint256)
    {
        require(
            ownerOf(tokenId1) == msg.sender && ownerOf(tokenId2) == msg.sender,
            "permission denied"
        );
        uint256 newItemId = _tokenIdTracker.current();
        string[] memory points1 = getPoints(tokenId1);
        string[] memory points2 = getPoints(tokenId2);
        bytes32[] memory newPoints = new bytes32[](points1.length.add(points2.length));
        uint256 index;
        for (uint256 i; i<points1.length; i++) {
            pointAllocation[points1[i]] = newItemId;
            newPoints[index] = stringToBytes32(points1[i]);
            index += 1;
        }
        for (uint256 i; i<points2.length; i++) {
            pointAllocation[points2[i]] = newItemId;
            newPoints[index] = stringToBytes32(points2[i]);
            index += 1;
        }
        tokenInfo[newItemId] = newPoints;

        burn(tokenId1);
        burn(tokenId2);

        _mint(msg.sender, newItemId);
        _tokenIdTracker.increment();

        emit Merge(tokenId1, tokenId2, newItemId);

        return newItemId;
    }

    function grantMinter(address minter) external onlyAdmin {
        grantRole(MINTER_ROLE, minter);
    }

    function revokeMinter(address minter) external onlyAdmin {
        revokeRole(MINTER_ROLE, minter);
    }

    function supportsInterface(bytes4 interfaceId)
        public view virtual override(ERC721, ERC721Enumerable, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _burn(uint256 tokenId)
        internal virtual override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public view virtual override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal virtual override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
        string[] memory points = getPoints(tokenId);
        for (uint256 i; i<points.length; i++) {
            pointOwner[points[i]] = to;
        }
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://api.jakaverse.com/land/metadata/";
    }

}

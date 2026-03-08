// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract SpaceLotTwin is ERC721, AccessControl {
    // One role for manufacturer but could add more e.g. Labs, distributer types, regulators etc
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");

    // Keeping track of the number of tokens - starts at 1
    uint256 public nextTokenId = 1;

    // Status of the lot/reel - simplified to be just active or flagged as having an issue.
    // A true implementation would might have "Expired", "In Review", "Tested", "Lost" etc
    enum Status {
        Active,
        Flagged
    }

    struct Twin {
        bytes32 lotHash;       // hash of lot id
        bytes32 reelHash;        // hash of reel id
        string partNumber;      // number of part
        uint256 quantity;        // number of units in this lot
        address manufacturer;    // manufacturer of the lot
        uint256 parentTokenId;   // 0 if an original, otherwise points to the parent token id (in case of splitting the lot)
        Status status;            // active or flagged
    }

    struct DocumentRef {
        bytes32 docHash;          // hash of off-chain file
        string uri;               // uri of off-chain file
    }

    // tokenId => twin data
    mapping(uint256 => Twin) public twins;

    // tokenId => linked documents
    mapping(uint256 => DocumentRef[]) public documents;

    // Events used to easily track different stages in 
    // the lot's lifecycle

    // Lot produced so manufacturer mints token 
    event TwinMinted(
        uint256 indexed tokenId,
        address indexed to,
        bytes32 lotHash,
        bytes32 reelHash,
        string partNumber,
        uint256 quantity
    );
    
    // Lot ownership transferred
    event CustodyTransferred(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to
    );

    // Lot/reel split producing child tokens
    event ReelSplit(
        uint256 indexed parentTokenId,
        uint256 indexed childTokenId,
        uint256 childQuantity,
        address indexed recipient
    );

    // document added offline and synced on-chain
    event DocumentAdded(
        uint256 indexed tokenId,
        bytes32 indexed docHash,
        string uri
    );

    // Status changed (Active or flagged)
    event StatusUpdated(
        uint256 indexed tokenId,
        Status newStatus
    );

    // Two simple roles used but can add more
    constructor() ERC721("Space Lot Twin", "SLT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANUFACTURER_ROLE, msg.sender);
    }

    // Mint a new token representing a lot/reel - only done by manufacturer
    function mintTwin(
        address to,
        bytes32 lotHash,
        bytes32 reelHash,
        string memory partNumber,
        uint256 quantity
    ) external onlyRole(MANUFACTURER_ROLE) returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(quantity > 0, "Quantity must be > 0"); // Represents quantity of units inside lot, not number of tokens

        uint256 tokenId = nextTokenId;
        nextTokenId++;

        _safeMint(to, tokenId); // using default function to mint

        // Recording all the required details
        twins[tokenId] = Twin({
            lotHash: lotHash,
            reelHash: reelHash,
            partNumber: partNumber,
            quantity: quantity,
            manufacturer: msg.sender,
            parentTokenId: 0,
            status: Status.Active
        });
        
        // Logging so its easily accessible for audit/review
        emit TwinMinted(tokenId, to, lotHash, reelHash, partNumber, quantity);
        return tokenId;
    }


    // Transfer token (represents real transferral of lot)
    function transferCustody(uint256 tokenId, address to) external {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        require(to != address(0), "Invalid recipient");
        require(twins[tokenId].status == Status.Active, "Token is flagged");

        address from = msg.sender;
        _transfer(from, to, tokenId);

        emit CustodyTransferred(tokenId, from, to);
    }


    // Owner of lot can attach document reference. This could be extended so that tests can be 
    // done by labs and attached here with an incentive.
    function addDocument(
        uint256 tokenId,
        bytes32 docHash,
        string memory uri
    ) external {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "Not token owner");

        documents[tokenId].push(
            DocumentRef({
                docHash: docHash,
                uri: uri
            })
        );

        emit DocumentAdded(tokenId, docHash, uri);
    }

    // Simple flagging system, either owner or manufacturer can flag. Right now
    // it doesn't really do anything except block splitting, but in a real implementation there could be
    // flagging permissions, and a review state and an appeal etc
    function setStatus(uint256 tokenId, Status newStatus) external {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        require(
            ownerOf(tokenId) == msg.sender ||
                twins[tokenId].manufacturer == msg.sender,
            "Not allowed"
        );

        twins[tokenId].status = newStatus;
        emit StatusUpdated(tokenId, newStatus);
    }


    // Splitting lot/reel. This is the most complex function. 
    // Basically just minting new tokens and splitting it off from original
    function splitReel(
        uint256 tokenId,
        uint256[] memory childQuantities,
        address[] memory recipients
    ) external returns (uint256[] memory) {
        require(ownerOf(tokenId) == msg.sender, "Not token owner");
        require(twins[tokenId].status == Status.Active, "Token is flagged"); // Cannot split flagged lot
        require(childQuantities.length > 0, "No children"); // Must request at least 1 new token for it to be a split
        require(childQuantities.length == recipients.length, "Length mismatch"); // Each child token must go to a unqiue firm. In practise it may make sense to allow for multiple children going to the same firm.

        
        uint256 totalSplit = 0;
        for (uint256 i = 0; i < childQuantities.length; i++) {
            require(childQuantities[i] > 0, "Child quantity must be > 0");
            require(recipients[i] != address(0), "Invalid recipient");
            totalSplit += childQuantities[i];
        }
        // ensure child token(s) sum to at most the original number of units in lot
        require(totalSplit <= twins[tokenId].quantity, "Split exceeds quantity");

        twins[tokenId].quantity -= totalSplit;
        
        // 
        uint256[] memory newIds = new uint256[](childQuantities.length);
        
        // Minting the child tokens
        for (uint256 i = 0; i < childQuantities.length; i++) {
            uint256 childId = nextTokenId;
            // Making sure these are added to canonical record of existing tokens
            nextTokenId++;

            _safeMint(recipients[i], childId);
            
            // Child properties are basically the same except it has a different ID and quantity
            twins[childId] = Twin({
                lotHash: twins[tokenId].lotHash,
                reelHash: keccak256(abi.encodePacked(twins[tokenId].reelHash, childId)),
                partNumber: twins[tokenId].partNumber,
                quantity: childQuantities[i],
                manufacturer: twins[tokenId].manufacturer,
                parentTokenId: tokenId,
                status: Status.Active
            });

            newIds[i] = childId;
            emit ReelSplit(tokenId, childId, childQuantities[i], recipients[i]);
        }

        return newIds;
    }

    // Allows external viewing of document info in the tokens
    function getDocumentCount(uint256 tokenId) external view returns (uint256) {
        return documents[tokenId].length;
    }

    // Retrieve a specific document by index
    function getDocument(
        uint256 tokenId,
        uint256 index
    ) external view returns (bytes32 docHash, string memory uri) {
        DocumentRef memory d = documents[tokenId][index];
        return (d.docHash, d.uri);
    }

    // Not sure exactly what this function does but I was getting an 
    //error I didn't understand and AI recommended it. I think it handles import conflicts.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

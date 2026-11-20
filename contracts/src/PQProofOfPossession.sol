// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {LeanXmss} from "./LeanXmss.sol";

/// @title PQProofOfPossession
/// @notice Checks the leanXMSS proof of possession of a PQ registration request. The geas
///         registration contracts in ethereum/sys-asm call it for every request.
/// @dev There is no Solidity ABI. The calldata is 2484 bytes:
///        bls_pubkey (48) ‖ xmss_pubkey (32) ‖ signature (2404)
///      The call returns the 32-byte word 1 if the signature is a proof of possession: a
///      signature at leaf 0 by the XMSS key, over
///        M = keccak256(POP_DOMAIN ‖ chain_id (32) ‖ bls_pubkey (48) ‖ xmss_pubkey (32)).
///      It reverts with no data for anything else, including calldata of another length.
///
///      This is the check `RegistrationQueue` does inline. The contract has no storage and
///      takes no value, so it can be called with STATICCALL.
contract PQProofOfPossession {
    uint256 internal constant BLS_PUBKEY_LENGTH = 48;
    uint256 internal constant XMSS_PUBKEY_LENGTH = 32;
    uint256 internal constant KEYS_LENGTH = BLS_PUBKEY_LENGTH + XMSS_PUBKEY_LENGTH;
    uint32 internal constant POP_LEAF_INDEX = 0;
    bytes32 internal constant POP_DOMAIN =
        keccak256("leanXMSS registration proof of possession v1");

    fallback() external {
        bytes calldata input = msg.data;
        if (input.length != KEYS_LENGTH + LeanXmss.SIGNATURE_LENGTH) revert();
        bytes calldata signature = input[KEYS_LENGTH:];
        bytes32 xmssPubkey = bytes32(input[BLS_PUBKEY_LENGTH:KEYS_LENGTH]);
        if (LeanXmss.signatureIndex(signature) != POP_LEAF_INDEX) revert();

        // The preimage of `M` is written at the free memory pointer without allocating it,
        // since nothing reads it after the hash. `verify` then finds no allocated memory to save.
        bytes32 domain = POP_DOMAIN;
        bytes32 message;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, domain)
            mstore(add(p, 0x20), chainid())
            let keys := add(BLS_PUBKEY_LENGTH, XMSS_PUBKEY_LENGTH)
            calldatacopy(add(p, 0x40), input.offset, keys)
            message := keccak256(p, add(0x40, keys))
        }
        if (!LeanXmss.verify(xmssPubkey, message, signature)) revert();

        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}

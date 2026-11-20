// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RegistrationTestBase} from "./helpers/RegistrationTestBase.sol";
import {PQProofOfPossession} from "../src/PQProofOfPossession.sol";

/// Tests the proof of possession contract on its own. Its calldata is a builder request, so the
/// builder registration contract, which does the same check inline, is its reference.
contract PQProofOfPossessionTest is RegistrationTestBase {
    address internal verifier;

    function setUp() public override {
        super.setUp();
        verifier = address(new PQProofOfPossession());
    }

    function isValidator() internal pure override returns (bool) {
        return false;
    }

    /// Calls the verifier as the geas contracts do, with a STATICCALL, and returns whether it
    /// accepted the proof. A call either returns the word 1 or reverts with no data.
    function accepts(bytes memory data) internal view returns (bool) {
        (bool ok, bytes memory out) = verifier.staticcall(data);
        if (ok) assertEq(out, abi.encode(uint256(1)));
        else assertEq(out.length, 0);
        return ok;
    }

    function test_AcceptsProofs() public view {
        for (uint256 i; i < 3; i++) {
            assertTrue(accepts(request(proof(i))));
        }
    }

    function test_RevertWhen_NotRequestLength() public view {
        Proof memory p = proof(0);
        assertFalse(accepts(""));
        assertFalse(accepts(input(p)));
        assertFalse(accepts(p.signature));
        assertFalse(accepts(bytes.concat(request(p), hex"00")));
        // A validator request, which has 32 bytes of VRF data before the signature.
        assertFalse(accepts(bytes.concat(input(p), bytes32(0), p.signature)));
        bytes memory short = request(p);
        assembly {
            mstore(short, sub(mload(short), 1))
        }
        assertFalse(accepts(short));
    }

    function test_RevertWhen_OtherChain() public {
        vm.chainId(1);
        assertFalse(accepts(request(proof(0))));
    }

    function test_RevertWhen_OtherKey() public view {
        Proof memory p = proof(0);
        p.blsPubkey = proof(1).blsPubkey;
        assertFalse(accepts(request(p)));
        p = proof(0);
        p.xmssPubkey = proof(1).xmssPubkey;
        assertFalse(accepts(request(p)));
    }

    function test_RevertWhen_MessageWithoutDomain() public view {
        assertFalse(accepts(request(proofAt(".noDomain"))));
    }

    function test_RevertWhen_NotAtLeafZero() public view {
        assertFalse(accepts(request(proofAt(".wrongLeaf"))));
    }

    function test_RevertWhen_CallCarriesValue() public {
        (bool ok,) = verifier.call{value: 1}(request(proof(0)));
        assertFalse(ok);
    }

    /// The verifier accepts exactly what the builder registration contract accepts: a proof with
    /// any one bit changed, or calldata of any other length.
    function testFuzz_AgreesWithBuilderRegistration(uint256 i, uint256 bit, bool flip, uint256 cut)
        public
    {
        bytes memory data = request(proof(i % 3));
        if (flip) {
            bit = bound(bit, 0, 8 * data.length - 1);
            data[bit / 8] ^= bytes1(uint8(1 << (bit % 8)));
        }
        if (cut % 8 == 0) {
            cut = bound(cut, 0, data.length);
            assembly {
                mstore(data, cut)
            }
        }
        assertEq(accepts(data), submit(registration, data));
    }
}

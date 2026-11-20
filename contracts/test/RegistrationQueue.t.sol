// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {RegistrationTestBase} from "./helpers/RegistrationTestBase.sol";

/// Compares the registration contract against another bytecode. Every call goes to both, and the
/// two must agree on success, return data, logs, storage and balance. The other bytecode is:
/// - The EIP's, which takes a request without the signature.
/// - The geas contract of ethereum/sys-asm, which takes the same request as the registration
///   contract and calls `PQProofOfPossession` to check the proof.
abstract contract RegistrationQueueTest is RegistrationTestBase {
    /// The other bytecode.
    address internal other;

    Proof[3] internal proofs;

    function setUp() public override {
        super.setUp();
        if (againstSysAsm()) {
            other = deploySysAsm(isValidator());
        } else {
            // The EIP hasn't chosen its address yet.
            other = address(0x8483);
            vm.etch(other, eipRuntime());
        }
        for (uint256 i; i < 3; i++) {
            proofs[i] = proof(i);
        }
    }

    /// Whether the other bytecode is the geas contract of ethereum/sys-asm or the EIP's.
    function againstSysAsm() internal pure virtual returns (bool) {
        return false;
    }

    function otherName() internal pure returns (string memory) {
        return againstSysAsm() ? "sys-asm bytecode" : "EIP bytecode";
    }

    /// The request for `p` as the other bytecode takes it.
    function otherRequest(Proof memory p) internal pure returns (bytes memory) {
        return againstSysAsm() ? request(p) : input(p);
    }

    // --- Calls to both contracts --------------------------------------------------------------

    /// Calls the fee getter on both. `fee` is zero when both revert.
    function feeOfBoth() internal returns (bool ok, uint256 fee) {
        (bool okOther, bytes memory retOther) = other.call("");
        (bool okOurs, bytes memory retOurs) = registration.call("");
        assertEq(okOurs, okOther, "fee getter: success");
        assertEq(retOurs, retOther, "fee getter: return data");
        assertSameState();
        if (okOther) fee = abi.decode(retOther, (uint256));
        return (okOther, fee);
    }

    /// Adds proof `i` to both from `sender`, paying `value`.
    function addToBoth(address sender, uint256 i, uint256 value) internal returns (bool) {
        Proof memory p = proofs[i];
        return sendToBoth(sender, request(p), otherRequest(p), value);
    }

    /// Sends `ours` to the registration contract and `theirs` to the other bytecode, from
    /// `sender` and paying `value`.
    function sendToBoth(address sender, bytes memory ours, bytes memory theirs, uint256 value)
        internal
        returns (bool)
    {
        uint256 tail = load(other, 3);
        vm.deal(sender, 2 * value);
        vm.recordLogs();
        vm.prank(sender);
        (bool okOther, bytes memory retOther) = other.call{value: value}(theirs);
        Vm.Log[] memory logsOther = vm.getRecordedLogs();
        vm.prank(sender);
        (bool okOurs, bytes memory retOurs) = registration.call{value: value}(ours);
        Vm.Log[] memory logsOurs = vm.getRecordedLogs();

        assertEq(okOurs, okOther, "add: success");
        assertEq(retOurs, retOther, "add: return data");
        assertEq(logsOurs.length, logsOther.length, "add: logs");
        for (uint256 j; j < logsOther.length; j++) {
            assertEq(logsOurs[j].topics.length, logsOther[j].topics.length, "add: log topics");
            assertEq(logsOurs[j].data, logsOther[j].data, "add: log data");
        }
        assertSameState();
        assertSameRequests(tail, 1);
        return okOther;
    }

    /// Runs the system call on both, with `data` as calldata.
    function systemCallBoth(bytes memory data) internal returns (bytes memory records) {
        vm.prank(SYSTEM_ADDRESS);
        (bool okOther, bytes memory retOther) = other.call(data);
        vm.prank(SYSTEM_ADDRESS);
        (bool okOurs, bytes memory retOurs) = registration.call(data);
        assertTrue(okOther, "system call failed");
        assertEq(okOurs, okOther, "system call: success");
        assertEq(retOurs, retOther, "system call: return data");
        assertSameState();
        return retOther;
    }

    // --- State --------------------------------------------------------------------------------

    function load(address target, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(target, bytes32(slot)));
    }

    function store(uint256 slot, uint256 value) internal {
        vm.store(other, bytes32(slot), bytes32(value));
        vm.store(registration, bytes32(slot), bytes32(value));
    }

    /// Sets slots 0 to 4 of both: excess, count, head, tail and last block.
    function setState(uint256 excess, uint256 count, uint256 head, uint256 tail, uint256 last)
        internal
    {
        store(0, excess);
        store(1, count);
        store(2, head);
        store(3, tail);
        store(4, last);
    }

    /// Fills `n` requests from index `from` in both, each slot with a hash of `seed` and the
    /// slot.
    function fillQueue(uint256 from, uint256 n, bytes32 seed) internal {
        unchecked {
            uint256 first = QUEUE_OFFSET + from * slotsPerRequest();
            for (uint256 slot = first; slot != first + n * slotsPerRequest(); slot++) {
                store(slot, uint256(keccak256(abi.encode(seed, slot))));
            }
        }
    }

    function assertSameState() internal view {
        for (uint256 slot; slot < QUEUE_OFFSET; slot++) {
            assertEq(load(registration, slot), load(other, slot), "storage slot");
        }
        assertEq(registration.balance, other.balance, "balance");
    }

    /// Checks that both store the same `n` requests from index `from`, and the same slot after
    /// them.
    function assertSameRequests(uint256 from, uint256 n) internal view {
        unchecked {
            uint256 first = QUEUE_OFFSET + from * slotsPerRequest();
            for (uint256 slot = first; slot != first + n * slotsPerRequest() + 1; slot++) {
                assertEq(load(registration, slot), load(other, slot), "queue slot");
            }
        }
    }

    /// The EIP's `fake_exponential(MIN_FEE, exponent, FEE_UPDATE_FRACTION)`.
    function feeAt(uint256 exponent) internal pure returns (uint256) {
        uint256 output;
        uint256 accum = 17;
        for (uint256 i = 1; accum > 0; i++) {
            output += accum;
            accum = (accum * exponent) / (17 * i);
        }
        return output / 17;
    }

    function sender(uint256 j) internal pure returns (address) {
        return address(uint160(0x5e4de0000 + j));
    }

    // --- Fees ---------------------------------------------------------------------------------

    /// The contract takes requests right after deployment, without a system call first.
    function test_AcceptsRequestsFromDeployment() public {
        (bool ok, uint256 fee) = feeOfBoth();
        assertTrue(ok);
        assertEq(fee, 1);
        assertTrue(addToBoth(sender(0), 0, fee));
    }

    /// Within a block, each request above the target raises the fee. In later blocks, the excess
    /// decays by the target per block.
    function test_FeeAcrossBlocks() public {
        uint256 fee;
        for (uint256 j; j < maxAddedPerBlock(); j++) {
            (, fee) = feeOfBoth();
            assertEq(fee, feeAt(j > target() ? j - target() : 0));
            assertTrue(addToBoth(sender(j), j % 3, fee));
        }
        uint256 excess = maxAddedPerBlock() - target();
        (, fee) = feeOfBoth();
        assertEq(fee, feeAt(excess));
        assertGt(fee, 1);

        // `elapsed` blocks later, the excess is that block's count minus `elapsed` targets.
        for (uint256 elapsed = 1; excess > 0; elapsed++) {
            vm.roll(block.number + 1);
            uint256 decay = elapsed * target();
            excess = maxAddedPerBlock() > decay ? maxAddedPerBlock() - decay : 0;
            (, fee) = feeOfBoth();
            assertEq(fee, feeAt(excess));
        }
        assertEq(fee, 1);

        // A request in a later block writes the decayed excess to storage.
        assertTrue(addToBoth(sender(0), 0, fee));
        assertEq(load(registration, 0), 0);
        assertEq(load(registration, 1), 1);
        assertEq(load(registration, 4), block.number);
    }

    function test_RevertWhen_FeeNotCovered() public {
        assertFalse(addToBoth(sender(0), 0, 0));
        // Overpaying works, and the contract keeps all of it.
        assertTrue(addToBoth(sender(0), 0, 5));
        assertEq(registration.balance, 5);
    }

    function test_RevertWhen_FeeGetterCarriesValue() public {
        (bool okOther,) = other.call{value: 1}("");
        (bool okOurs,) = registration.call{value: 1}("");
        assertFalse(okOther);
        assertFalse(okOurs);
    }

    function test_RevertWhen_BlockLimitReached() public {
        uint256 fee;
        for (uint256 j; j < maxAddedPerBlock(); j++) {
            (, fee) = feeOfBoth();
            assertTrue(addToBoth(sender(j), j % 3, fee));
        }
        (, fee) = feeOfBoth();
        assertFalse(addToBoth(sender(0), 0, fee));

        vm.roll(block.number + 1);
        (, fee) = feeOfBoth();
        assertTrue(addToBoth(sender(0), 0, fee));
    }

    function testFuzz_FeeGetter(
        uint256 excess,
        uint256 count,
        uint256 last,
        uint256 number,
        bool inhibited
    ) public {
        excess = inhibited ? type(uint256).max : bound(excess, 0, 10_000);
        vm.roll(bound(number, 0, type(uint64).max));
        setState(
            excess, bound(count, 0, 2 * maxAddedPerBlock()), 0, 0, bound(last, 0, type(uint64).max)
        );
        feeOfBoth();
    }

    /// Adds from any fee state, queue tail, sender and value, including states that no sequence
    /// of calls reaches, such as a last block after the current one.
    function testFuzz_Add(
        uint256 excess,
        uint256 count,
        uint256 last,
        uint256 number,
        uint256 tail,
        address from,
        uint256 i,
        uint256 value
    ) public {
        // The system address would take the system call path, and the test funds the sender, so
        // sending from either contract would change its balance.
        vm.assume(from != SYSTEM_ADDRESS && from != other && from != registration);
        vm.roll(bound(number, 0, type(uint64).max));
        setState(
            bound(excess, 0, 1000),
            bound(count, 0, maxAddedPerBlock()),
            0,
            bound(tail, 0, type(uint64).max),
            bound(last, 0, type(uint64).max)
        );
        (, uint256 fee) = feeOfBoth();
        addToBoth(from, i % 3, bound(value, 0, 2 * fee + 1));
    }

    // --- Queue and system call ----------------------------------------------------------------

    function test_SystemCallReturnsRecordsInOrder() public {
        assertEq(systemCallBoth(""), "");
        for (uint256 j; j < 3; j++) {
            assertTrue(addToBoth(sender(j), j, 1));
        }
        bytes memory expected = bytes.concat(
            record(sender(0), proofs[0]), record(sender(1), proofs[1]), record(sender(2), proofs[2])
        );
        assertEq(systemCallBoth(""), expected);
        // The queue is empty again, so head and tail go back to 0.
        assertEq(load(registration, 2), 0);
        assertEq(load(registration, 3), 0);
    }

    function test_SystemCallDequeuesAtMostMaxPerBlock() public {
        uint256 n = maxPerBlock() + 3;
        fillQueue(0, n, "queue");
        store(3, n);
        assertEq(systemCallBoth("").length, maxPerBlock() * recordLength());
        assertEq(load(registration, 2), maxPerBlock());
        assertEq(load(registration, 3), n);
        assertEq(systemCallBoth("").length, 3 * recordLength());
        assertEq(load(registration, 2), 0);
        assertEq(load(registration, 3), 0);
    }

    /// Runs the system call from any queue position, length and contents, fee state and
    /// calldata, including a head past the tail.
    function testFuzz_SystemCall(
        uint256 head,
        uint256 tail,
        uint256 excess,
        uint256 count,
        bytes32 seed,
        bytes memory data
    ) public {
        head = bound(head, 0, type(uint64).max);
        if (tail % 8 != 0) tail = head + bound(tail, 0, 40);
        else tail = bound(tail, 0, type(uint64).max);
        if (tail >= head) {
            fillQueue(head, tail - head > maxPerBlock() ? maxPerBlock() : tail - head, seed);
        }
        if (excess % 4 == 0) excess = type(uint256).max;
        setState(excess, count, head, tail, 0);
        systemCallBoth(data);
    }

    /// A full block, as the EIP sizes it: the system call dequeues the maximum from cold storage
    /// within its 30M gas.
    function test_FullBlockSystemCallFitsGasLimit() public {
        fillQueue(0, maxPerBlock(), "full block");
        store(3, maxPerBlock());
        vm.cool(other);
        vm.cool(registration);

        uint256[2] memory used;
        address[2] memory contracts = [other, registration];
        for (uint256 c; c < 2; c++) {
            vm.prank(SYSTEM_ADDRESS);
            uint256 before = gasleft();
            (bool ok, bytes memory out) = contracts[c].call{gas: SYSTEM_CALL_GAS_LIMIT}("");
            used[c] = before - gasleft();
            assertTrue(ok);
            assertEq(out.length, maxPerBlock() * recordLength());
        }
        emit log_named_uint(string.concat("system call, full block, ", otherName()), used[0]);
        emit log_named_uint("system call, full block, this contract", used[1]);
        assertLt(used[1], SYSTEM_CALL_GAS_LIMIT);
    }

    // --- Inhibitor ----------------------------------------------------------------------------

    /// A system call with calldata disables the queue, and a later one without calldata re-enables
    /// it with a fresh fee state.
    function test_Inhibitor() public {
        for (uint256 j; j < 3; j++) {
            assertTrue(addToBoth(sender(j), j, 1));
        }
        systemCallBoth(hex"01");
        assertEq(load(registration, 0), type(uint256).max);
        (bool ok,) = feeOfBoth();
        assertFalse(ok);
        assertFalse(addToBoth(sender(0), 0, 1 ether));

        systemCallBoth("");
        assertEq(load(registration, 0), 0);
        assertEq(load(registration, 1), 0);
        (, uint256 fee) = feeOfBoth();
        assertEq(fee, 1);
        assertTrue(addToBoth(sender(0), 0, fee));
    }
}

/// The comparison with the geas contracts. They take the same request as the registration
/// contract, so requests that carry no valid proof are compared too.
abstract contract SysAsmQueueTest is RegistrationQueueTest {
    function againstSysAsm() internal pure override returns (bool) {
        return true;
    }

    /// Sends both a request with one bit changed, or of another length. They accept the same ones:
    /// a change in the signature or in what it signs is rejected, and one in the VRF data isn't.
    function testFuzz_AddChangedRequest(uint256 i, uint256 bit, bool flip, uint256 cut) public {
        bytes memory data = request(proofs[i % 3]);
        if (flip) {
            bit = bound(bit, 0, 8 * data.length - 1);
            data[bit / 8] ^= bytes1(uint8(1 << (bit % 8)));
        }
        if (cut % 8 == 0) {
            cut = bound(cut, 0, data.length + 32);
            if (cut > data.length) data = bytes.concat(data, new bytes(cut - data.length));
            assembly {
                mstore(data, cut)
            }
        }
        sendToBoth(sender(0), data, data, 1);
    }
}

contract ValidatorSysAsmQueueTest is SysAsmQueueTest {
    function isValidator() internal pure override returns (bool) {
        return true;
    }
}

contract BuilderSysAsmQueueTest is SysAsmQueueTest {
    function isValidator() internal pure override returns (bool) {
        return false;
    }
}

contract ValidatorRegistrationQueueTest is RegistrationQueueTest {
    function isValidator() internal pure override returns (bool) {
        return true;
    }
}

contract BuilderRegistrationQueueTest is RegistrationQueueTest {
    function isValidator() internal pure override returns (bool) {
        return false;
    }
}

"""Parser contracts for retained XCTest logs; these are not native tests."""
import unittest
from check_cache_native_receipt import EXPECTED, OWNER, inspect


def transcript(style='apple', failures=frozenset(), *, owner=OWNER, expected=EXPECTED):
    lines = [f"Test Suite '{owner}' started at date."]
    for name in sorted(expected):
        identifier = f"-[RealmSwiftGapsTests.{owner} {name}]" if style == 'apple' else f"{owner}.{name}"
        lines.extend([f"Test Case '{identifier}' started.",
                      f"Test Case '{identifier}' {'failed' if name in failures else 'passed'} (0.001 seconds)."])
    lines.extend([f"Test Suite '{owner}' {'failed' if failures else 'passed'} at date.",
                  f"Executed {len(expected)} tests, with {len(failures)} failures (0 unexpected).", "Test run with 0 tests passed after 0.001 seconds."])
    return '\n'.join(lines)


class ReceiptContracts(unittest.TestCase):
    def test_explicit_component_inventory_has_independent_accounting(self):
        owner = 'RealmReadLockedWriteTests'
        expected = frozenset({'testSourceOwner', 'testDestinationOwner'})
        log = transcript(owner=owner, expected=expected)
        self.assertFalse(inspect(log, 0)['contract_passed'])
        receipt = inspect(log, 0, owner=owner, expected=expected)
        self.assertTrue(receipt['contract_passed'])
        self.assertEqual(receipt['native_successful_methods'], 2)
        self.assertEqual(receipt['required_methods'], sorted(expected))

    def test_explicit_component_inventory_rejects_missing_identity(self):
        expected = frozenset({'testSourceOwner', 'testDestinationOwner'})
        log = transcript(owner='OwnedTests', expected=expected)
        log = '\n'.join(line for line in log.splitlines() if 'testSourceOwner' not in line)
        self.assertFalse(inspect(log, 0, owner='OwnedTests', expected=expected)['contract_passed'])

    def test_explicit_component_inventory_rejects_wrong_same_count(self):
        expected = frozenset({'testSourceOwner', 'testDestinationOwner'})
        log = transcript(owner='OwnedTests', expected=expected).replace('testSourceOwner', 'testOtherOwner')
        self.assertFalse(inspect(log, 0, owner='OwnedTests', expected=expected)['contract_passed'])

    def test_empty_or_invalid_explicit_inventory_is_not_a_pass(self):
        log = transcript(owner='OwnedTests', expected=frozenset())
        self.assertFalse(inspect(log, 0, owner='OwnedTests', expected=frozenset())['contract_passed'])
        self.assertFalse(inspect(log, 0, owner='', expected=frozenset({'testOwner'}))['contract_passed'])

    def test_complete_apple_events(self):
        self.assertTrue(inspect(transcript(), 0)['contract_passed'])

    def test_complete_portable_events(self):
        self.assertTrue(inspect(transcript('portable'), 0)['contract_passed'])

    def test_empty_secondary_runner_is_not_evidence(self):
        self.assertFalse(inspect('Test run with 0 tests passed.', 0)['contract_passed'])

    def test_summary_alone_is_not_evidence(self):
        self.assertFalse(inspect('Executed 6 tests, with 0 failures.', 0)['contract_passed'])

    def test_missing_method_fails(self):
        name = sorted(EXPECTED)[0]
        log = '\n'.join(line for line in transcript().splitlines() if name not in line)
        self.assertFalse(inspect(log, 0)['contract_passed'])

    def test_duplicate_terminal_fails(self):
        log = transcript()
        line = next(line for line in log.splitlines() if line.startswith('Test Case') and 'passed (' in line)
        self.assertFalse(inspect(log.replace(line, line+'\n'+line), 0)['contract_passed'])

    def test_failed_method_fails_positive_receipt(self):
        self.assertFalse(inspect(transcript(failures=frozenset([sorted(EXPECTED)[0]])), 1)['contract_passed'])

    def test_skipped_method_fails(self):
        self.assertFalse(inspect(transcript().replace('passed (0.001 seconds).', 'skipped (0.001 seconds).', 1), 0)['contract_passed'])

    def test_native_process_failure_cannot_be_hidden(self):
        self.assertFalse(inspect(transcript(), 65)['contract_passed'])

    def test_wrong_class_does_not_satisfy_inventory(self):
        self.assertFalse(inspect(transcript().replace(OWNER, 'OtherTests'), 0)['contract_passed'])

    def test_method_outside_owning_suite_is_rejected(self):
        lines = transcript().splitlines()
        start = lines.pop(0)
        lines.insert(-1, start)
        self.assertFalse(inspect('\n'.join(lines), 0)['contract_passed'])

    def test_unexpected_identity_is_rejected(self):
        log = transcript().replace(f"Test Suite '{OWNER}' passed", f"Test Case '-[Module.{OWNER} testExtra]' started.\nTest Case '-[Module.{OWNER} testExtra]' passed (0.001 seconds).\nTest Suite '{OWNER}' passed")
        self.assertFalse(inspect(log, 0)['contract_passed'])

    def test_exact_negative_control_history(self):
        failures = frozenset(sorted(EXPECTED)[:2])
        receipt = inspect(transcript(failures=failures), 1, failures)
        self.assertTrue(receipt['contract_passed'])
        self.assertEqual(receipt['native_successful_methods'], 4)

    def test_wrong_negative_control_does_not_pass(self):
        failures = frozenset(sorted(EXPECTED)[:2])
        self.assertFalse(inspect(transcript(), 0, failures)['contract_passed'])

    def test_negative_control_does_not_accept_termination(self):
        failures = frozenset(sorted(EXPECTED)[:2])
        self.assertFalse(inspect(transcript(failures=failures), 143, failures)['contract_passed'])

    def test_unexpected_exception_is_not_the_expected_regression(self):
        failures = frozenset(sorted(EXPECTED)[:2])
        log = transcript(failures=failures).replace('(0 unexpected)', '(1 unexpected)')
        self.assertFalse(inspect(log, 1, failures)['contract_passed'])

    def test_duplicate_suite_or_incomplete_terminal_fails(self):
        log = transcript()
        self.assertFalse(inspect(log+'\n'+log, 0)['contract_passed'])
        self.assertFalse(inspect(log.replace(f"Test Suite '{OWNER}' passed at date.", ''), 0)['contract_passed'])


if __name__ == '__main__':
    unittest.main()

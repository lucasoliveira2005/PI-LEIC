import os
import unittest

from shared.env_utils import (
    parse_bool_env,
    parse_float_env,
    parse_non_negative_float_env,
    parse_non_negative_int_env,
    parse_positive_int_env,
)


class ParseNonNegativeIntEnvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("_TEST_INT_VAR", None)

    def tearDown(self):
        os.environ.pop("_TEST_INT_VAR", None)

    def test_returns_default_when_missing(self):
        self.assertEqual(parse_non_negative_int_env("_TEST_INT_VAR", 42), 42)

    def test_parses_valid_zero(self):
        os.environ["_TEST_INT_VAR"] = "0"
        self.assertEqual(parse_non_negative_int_env("_TEST_INT_VAR", 1), 0)

    def test_parses_positive_integer(self):
        os.environ["_TEST_INT_VAR"] = "100"
        self.assertEqual(parse_non_negative_int_env("_TEST_INT_VAR", 0), 100)

    def test_raises_on_negative(self):
        os.environ["_TEST_INT_VAR"] = "-1"
        with self.assertRaises(ValueError):
            parse_non_negative_int_env("_TEST_INT_VAR", 0)

    def test_raises_on_non_numeric(self):
        os.environ["_TEST_INT_VAR"] = "abc"
        with self.assertRaises(ValueError):
            parse_non_negative_int_env("_TEST_INT_VAR", 0)


class ParsePositiveIntEnvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("_TEST_POS_INT_VAR", None)

    def tearDown(self):
        os.environ.pop("_TEST_POS_INT_VAR", None)

    def test_returns_default_when_missing(self):
        self.assertEqual(parse_positive_int_env("_TEST_POS_INT_VAR", 5), 5)

    def test_parses_positive_integer(self):
        os.environ["_TEST_POS_INT_VAR"] = "3"
        self.assertEqual(parse_positive_int_env("_TEST_POS_INT_VAR", 1), 3)

    def test_raises_on_zero(self):
        os.environ["_TEST_POS_INT_VAR"] = "0"
        with self.assertRaises(ValueError):
            parse_positive_int_env("_TEST_POS_INT_VAR", 1)

    def test_raises_on_negative(self):
        os.environ["_TEST_POS_INT_VAR"] = "-5"
        with self.assertRaises(ValueError):
            parse_positive_int_env("_TEST_POS_INT_VAR", 1)


class ParseNonNegativeFloatEnvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("_TEST_FLOAT_VAR", None)

    def tearDown(self):
        os.environ.pop("_TEST_FLOAT_VAR", None)

    def test_returns_default_when_missing(self):
        self.assertAlmostEqual(parse_non_negative_float_env("_TEST_FLOAT_VAR", 1.5), 1.5)

    def test_parses_zero(self):
        os.environ["_TEST_FLOAT_VAR"] = "0.0"
        self.assertAlmostEqual(parse_non_negative_float_env("_TEST_FLOAT_VAR", 1.0), 0.0)

    def test_parses_positive_float(self):
        os.environ["_TEST_FLOAT_VAR"] = "3.14"
        self.assertAlmostEqual(parse_non_negative_float_env("_TEST_FLOAT_VAR", 0.0), 3.14)

    def test_raises_on_negative(self):
        os.environ["_TEST_FLOAT_VAR"] = "-0.1"
        with self.assertRaises(ValueError):
            parse_non_negative_float_env("_TEST_FLOAT_VAR", 0.0)

    def test_raises_on_non_numeric(self):
        os.environ["_TEST_FLOAT_VAR"] = "not_a_number"
        with self.assertRaises(ValueError):
            parse_non_negative_float_env("_TEST_FLOAT_VAR", 0.0)


class ParseFloatEnvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("_TEST_ANY_FLOAT_VAR", None)

    def tearDown(self):
        os.environ.pop("_TEST_ANY_FLOAT_VAR", None)

    def test_returns_default_when_missing(self):
        self.assertAlmostEqual(parse_float_env("_TEST_ANY_FLOAT_VAR", -1.0), -1.0)

    def test_accepts_negative_float(self):
        os.environ["_TEST_ANY_FLOAT_VAR"] = "-99.5"
        self.assertAlmostEqual(parse_float_env("_TEST_ANY_FLOAT_VAR", 0.0), -99.5)

    def test_accepts_positive_float(self):
        os.environ["_TEST_ANY_FLOAT_VAR"] = "2.718"
        self.assertAlmostEqual(parse_float_env("_TEST_ANY_FLOAT_VAR", 0.0), 2.718)

    def test_raises_on_non_numeric(self):
        os.environ["_TEST_ANY_FLOAT_VAR"] = "x"
        with self.assertRaises(ValueError):
            parse_float_env("_TEST_ANY_FLOAT_VAR", 0.0)


class ParseBoolEnvTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("_TEST_BOOL_VAR", None)

    def tearDown(self):
        os.environ.pop("_TEST_BOOL_VAR", None)

    def test_returns_default_when_missing(self):
        self.assertTrue(parse_bool_env("_TEST_BOOL_VAR", True))
        self.assertFalse(parse_bool_env("_TEST_BOOL_VAR", False))

    def test_truthy_values(self):
        for value in ("1", "true", "True", "TRUE", "yes", "YES", "on", "ON"):
            os.environ["_TEST_BOOL_VAR"] = value
            self.assertTrue(
                parse_bool_env("_TEST_BOOL_VAR", False),
                msg=f"Expected True for {value!r}",
            )

    def test_falsy_values(self):
        for value in ("0", "false", "False", "FALSE", "no", "NO", "off", "OFF"):
            os.environ["_TEST_BOOL_VAR"] = value
            self.assertFalse(
                parse_bool_env("_TEST_BOOL_VAR", True),
                msg=f"Expected False for {value!r}",
            )


if __name__ == "__main__":
    unittest.main()

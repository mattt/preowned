import json
import unittest
from unittest.mock import Mock

from Scripts.smoke import check_structured_output


class StructuredOutputTests(unittest.TestCase):
    def test_wheel_count(self):
        client = Mock()
        for wheels, valid in (
            (True, False),
            (False, False),
            (0, True),
            (18, True),
            (19, False),
        ):
            with self.subTest(wheels=wheels):
                content = json.dumps(
                    {"name": "Wagon", "wheels": wheels, "condition": "used"}
                )
                choice = Mock()
                choice.message.content = content
                client.chat.completions.create.return_value.choices = [choice]
                if valid:
                    self.assertEqual(check_structured_output(client), content)
                else:
                    with self.assertRaises(AssertionError):
                        check_structured_output(client)

import io
import unittest

from remotex_server import screen as S

try:
    import PIL  # noqa: F401
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False


class ScreenTests(unittest.TestCase):
    def test_fake_without_pillow_still_gives_bytes(self):
        self.assertTrue(S.FakeScreen().grab(320, 40).startswith(b'\xff\xd8'))

    def test_clamp(self):
        self.assertEqual(S.clamp_options(None, None), (640, 45))
        self.assertEqual(S.clamp_options(99999, 1), (1280, 20))
        self.assertEqual(S.clamp_options(10, 500), (240, 80))
        self.assertEqual(S.clamp_options(True, "x"), (640, 45))
        self.assertEqual(S.clamp_options(float("nan"), 50), (640, 50))

    @unittest.skipUnless(HAVE_PIL, 'Pillow not installed')
    def test_fake_frames_are_jpeg_and_scaled(self):
        from PIL import Image
        src = S.FakeScreen()
        a, b = src.grab(480, 40), src.grab(480, 40)
        self.assertTrue(a.startswith(b"\xff\xd8"))
        self.assertNotEqual(a, b)
        self.assertEqual(Image.open(io.BytesIO(a)).size[0], 480)

    @unittest.skipUnless(HAVE_PIL, 'Pillow not installed')
    def test_encode_downscales_and_draws_cursor(self):
        from PIL import Image
        big = Image.new("RGB", (1920, 1080), (0, 0, 0))
        plain = S.encode(big, 640, 50)
        with_cursor = S.encode(big, 640, 50, (0.5, 0.5))
        img = Image.open(io.BytesIO(with_cursor))
        self.assertEqual(img.size, (640, 360))
        self.assertNotEqual(plain, with_cursor)
        self.assertGreater(max(img.getpixel((322, 185))), 100)  # white pointer near the middle


if __name__ == "__main__":
    unittest.main()

"""What a prompt says, as the stand-in's scripts read it, and as it was sent.

XCUI's typing can give a character as its CJK compatibility ideograph: in run 129 「断线：跟不上」 came
with 不 as U+F967, which reads the same and is another code point, so the script matched on the
words as sent was not found and the sentence was only echoed. fake_hermes.py reads every
prompt.submit through `read` (its NFC form: U+F967 is 不 again), so every module's scripts see the
words as written. What the stand-in stores keeps what was sent, as Hermes stores what it gets: an
admission, and the user's row in the transcript take `sent(text)`.

Stdlib only.
"""
import threading
import unicodedata

_lock = threading.Lock()
_sent = {}  # the words as read -> as sent, where the two differ


def read(text):
    """The words as the scripts read them: NFC. Remembers what was sent, for `sent`."""
    if not isinstance(text, str):
        return text
    plain = unicodedata.normalize("NFC", text)
    if plain != text:
        with _lock:
            _sent[plain] = text
    return plain


def sent(text):
    """What was sent for words read as `text`: the same words, unless the typing gave other code
    points for them."""
    if not isinstance(text, str):
        return text
    with _lock:
        return _sent.get(text, text)

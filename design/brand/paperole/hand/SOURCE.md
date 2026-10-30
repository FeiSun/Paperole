# Proust's hand: source and licence

`proust-longtemps.svg` (groups `line1` and `line2`), `proust-longtemps-line1.svg` and `proust-longtemps-line2.svg` are vector tracings of Marcel Proust's handwritten insertion "Longtemps, je me suis / couché de bonne heure", the first sentence of *Du côté de chez Swann* (1913), as he wrote it into a corrected proof.

## Source

- File: "Autographe Proust longtemps.JPG", Wikimedia Commons
  - Page: <https://commons.wikimedia.org/wiki/File:Autographe_Proust_longtemps.JPG>
  - Original: <https://upload.wikimedia.org/wikipedia/commons/8/8b/Autographe_Proust_longtemps.JPG>
- Photo: Warburg, 2013
- Photo licence: CC BY-SA 3.0 (also GFDL)
- File traced: 1782 × 1147 JPEG, 693,591 bytes, SHA-256 `460491e92f89b08008262b7e9c238b17aaa6216a95f329a092f3b3b943a34984`
- The handwriting is Proust's (died 1922) and is in the public domain.

Only the two handwritten lines were traced. The balloon Proust drew around them, the printed text, the margin bracket and the struck words "me coucher" are left out.

## Required credit

Wherever these paths or anything made from them is shown or shipped (the app icon, the README, the About box), give this credit:

> Handwriting: Marcel Proust (public domain); traced from a photo by Warburg, Wikimedia Commons, CC BY-SA 3.0

## Licence of the traced paths

The traced paths are shared under **CC BY-SA 4.0** (<https://creativecommons.org/licenses/by-sa/4.0/>):

- CC BY-SA 3.0 allows an adaptation to be licensed under a later version with the same elements, so 4.0 is allowed.
- CC BY-SA 4.0 is one-way compatible with GPLv3: material under it can be used in a GPLv3 work.

Each SVG carries the credit and the licence in its `<desc>`.

## How it was made

`src/trace.py` re-creates the three SVGs from the photo. Run it with `python3 -I src/trace.py <the JPEG> <out dir>`. It needs numpy, scipy, scikit-image and Pillow. The method is described at the top of the script.

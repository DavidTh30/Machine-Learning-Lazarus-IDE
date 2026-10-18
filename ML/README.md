# Lazarus OCR — learn and read text from images

A self-learning OCR program written in Lazarus / Free Pascal with no external libraries.

Open `LazOCR.lpi` in the Lazarus IDE and press Run (F9), or build with `lazbuild LazOCR.lpi`.
Press **F1** or click **Help** in the program for the full user guide.

## Workflow

**Learn tab**
1. Open an image (or drag & drop, or paste), or click **Generate from font...**
2. Type the text in the image, click **Segment symbols**, then **Add as training samples**.
3. **Learn from multiple images (same label)...** adds many images of the same character or word
   in one step. Tick **Whole image is ONE symbol** to learn each image as a single item (whole word).
4. Click **Start training** to train the neural network.

**Read tab**: **Read text from image** or **Read multiple images...**, using one of the classifiers
(MLP, k-NN, nearest centroid, ensemble vote) or **Compare all methods**.

**Classes tab**: lists learned classes and sample counts; delete wrongly labelled classes.

The model is saved automatically to `default.ocrm` next to the exe on exit.

## How it works

| Step | Method | File |
|---|---|---|
| Binarization | Otsu threshold, automatic text polarity | `ocrengine.pas` |
| Line detection | horizontal projection, thin bands merged (Thai marks) | `ocrengine.pas` |
| Segmentation | 8-connected components, vertically stacked parts merged | `ocrengine.pas` |
| Features | 16×16 aspect-preserving grid + height/position in line (258 values) | `ocrengine.pas` |
| Classifiers | MLP (tanh + softmax, SGD, shift augmentation), k-NN, nearest centroid, ensemble | `ocrmodel.pas` |
| Word spacing | adaptive to the typical letter gap of each line | `ocrengine.pas` |

## Limitations
- Touching characters (cursive, handwriting) cannot be split — use whole-image mode instead.
- Images should be straight (not rotated).
- Symbols that differ only by size (o/O, s/S, l/I) are easily confused; teach several fonts.

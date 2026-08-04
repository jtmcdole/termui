# Tinpot Rendering Algorithm

This document outlines the pipeline for converting a True Color (24-bit) image into an optimal set of ANSI terminal characters, mirroring the internal logic of the C `tinpot` library.

## 1. Aspect Ratio & Image Scaling
Terminals render physical cells that are typically twice as tall as they are wide (a 1:2 aspect ratio). 
To preserve the image's proportions:
1. The target grid width (in cells) is defined by the user (e.g., 85).
2. The target grid height is calculated using the formula: `columns / (imageAspect * 2.0)`.
3. The image is scaled using bilinear interpolation so that each target terminal cell corresponds to a uniform 8x8 pixel block (64 pixels). Because we've already compensated for the 1:2 physical distortion in step 2 by halving the target height, these 8x8 square blocks mathematically stretch back into perfectly proportioned rectangles when rendered in the terminal.

## 2. Dominant Channel & Endpoint Extraction
For each 64-pixel block, we determine the optimal Foreground (`FG`) and Background (`BG`) colors. Rather than running a full K-means clustering from scratch, we use an extremely fast approximation:
1. Iterate over the block to find the minimum and maximum pixel values for each RGB channel independently.
2. Select the channel (Red, Green, or Blue) that exhibits the greatest variance (`max - min`).
3. The pixel containing the minimum value in that dominant channel becomes the baseline Background (`c1`). The pixel containing the maximum value becomes the baseline Foreground (`c2`).

## 3. Ideal Mask Generation
With `c1` and `c2` established, we determine the geometric structure of the cell:
1. Every pixel in the 64-pixel block is evaluated against `c1` and `c2` using a fast squared RGB distance metric.
2. If a pixel is closer to the Background (`c1`), it is mapped to a `0` bit.
3. If a pixel is closer to the Foreground (`c2`), it is mapped to a `1` bit.
4. This results in a 64-bit integer—the **Ideal Mask**—which perfectly represents the binary shape of the gradient or edge within the cell.

## 4. Structural Matching via Hamming Distance
Instead of evaluating the visual error of every possible Unicode character (which is computationally expensive), we perform a fast structural filter:
1. We maintain a precomputed library of Unicode Block and Border elements (e.g., `▀`, `▖`, `╱`), where each character is represented by its own 64-bit shape mask.
2. We compute the **Hamming Distance** between our cell's Ideal Mask and every symbol mask in the library. This is done using an XOR and popcount operation: `popcount(idealMask ^ symbolMask)`.
3. Because the colors can be swapped, we also check the inverted distance: `popcount(~idealMask ^ symbolMask)`.
4. We sort the library by the lowest Hamming distance to find the shapes that most closely match the cell's binary structure. We take the **Top 5** candidates for precise error evaluation.

## 5. Precise Error Evaluation (K-Means)
For the Top 5 structural candidates, we evaluate exactly how well they represent the cell's original colors:
1. Using the candidate's specific 64-bit mask, we partition the original 64 pixels back into Foreground and Background sets.
2. We calculate the true Arithmetic Mean (average) color for the foreground pixels, and the mean color for the background pixels.
3. We compute the total error by summing the squared distance of each original pixel to its assigned mean.
4. The candidate with the absolute lowest error is selected as the winner. Its calculated mean colors become the ANSI foreground and background colors printed to the terminal alongside the winning character. 

*(Note: In the event of a tie—for example, if the cell is perfectly uniform, causing `Space` and `Inverted Solid Block` to both yield 0 error—we rely on a deterministic tie-breaker that prefers standard, non-inverted symbols like `Space` to keep the ANSI output clean.)*

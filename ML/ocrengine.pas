unit OcrEngine;

{ Image processing for OCR:
  - convert the image to black and white (Otsu threshold)
  - split into lines, then into symbols using connected components
  - extract features: a GRID x GRID bitmap + position within the line }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, Graphics, IntfGraphics, FPImage, LazUTF8;

const
  GRID = 16;                      // size of the normalized symbol grid
  FEAT_DIM = GRID * GRID + 2;     // pixels + relative height + vertical position
  POS_WEIGHT = 2.0;               // weight of the position features

type
  TFeature = array of Single;
  TIntArr = array of Integer;
  TStringArr = array of string;

  TPolarity = (polAuto, polDarkOnLight, polLightOnDark);

  TBinImage = record
    W, H: Integer;
    Data: array of Byte;          // 1 = ink (part of a symbol), 0 = background
  end;

  TOcrOptions = record
    AutoThreshold: Boolean;
    Threshold: Integer;
    Polarity: TPolarity;
    MergeParts: Boolean;          // merge vertically stacked parts, e.g. the dot of i, Thai upper/lower vowels
    MinArea: Integer;             // smaller components are treated as noise
    SpaceRatio: Single;           // max gap (x line height) before a space is inserted
    WholeImage: Boolean;          // treat all ink in the image as ONE symbol (character or word)
    ThaiMarks: Boolean;           // Thai: upper/lower vowels and tone marks are separate symbols
  end;

  TGlyph = record
    R: TRect;                     // Right/Bottom are exclusive
    Line: Integer;
    LineTop, LineBottom: Integer;
    Ids: TIntArr;                 // ids of the components that form this symbol
    Feat: TFeature;
    Text: string;
    Conf: Single;
  end;
  TGlyphArray = array of TGlyph;

function DefaultOcrOptions: TOcrOptions;
function BitmapToBinary(Bmp: TBitmap; const Opt: TOcrOptions; out UsedThreshold: Integer): TBinImage;
function SegmentGlyphs(const Bin: TBinImage; const Opt: TOcrOptions): TGlyphArray;
// same, also returns the component label map needed by MergeGlyphs
function SegmentGlyphsEx(const Bin: TBinImage; const Opt: TOcrOptions; out Lab: TIntArr): TGlyphArray;
// manual corrections: merge symbol B into A (features are recomputed) / remove one symbol
procedure MergeGlyphs(const Bin: TBinImage; const Lab: TIntArr; var G: TGlyphArray; A, B: Integer);
procedure RemoveGlyph(var G: TGlyphArray; Idx: Integer);
function ShiftFeature(const F: TFeature; DX, DY: Integer): TFeature;
function IsCombiningMark(CP: Cardinal): Boolean;
const
  // label of the separate bottom stroke of Thai YO YING when marks are kept separate;
  // it is learned like any symbol and removed from the text that is read
  TAIL_YO_YING = '(' + #$E0#$B8#$8D + ')';

function TokenizeLabels(const S: string; SplitSpace, MergeCombining: Boolean): TStringArr;
function GlyphsToText(const G: TGlyphArray; const Opt: TOcrOptions): string;

implementation

const
  NIKHAHIT = #$E0#$B9#$8D;   // U+0E4D
  SARA_AA = #$E0#$B8#$B2;    // U+0E32
  SARA_AM = #$E0#$B8#$B3;    // U+0E33
  SARA_E = #$E0#$B9#$80;     // U+0E40
  SARA_AE = #$E0#$B9#$81;    // U+0E41 (drawn as two SARA E)
  YO_YING = #$E0#$B8#$8D;    // U+0E0D (its bottom stroke is a separate piece)

type
  TComp = record
    L, T, R, B: Integer;
    Area: Integer;
    Ids: TIntArr;
    Zone: Integer;      // Thai mode: 0 = body (middle zone), 1 = mark above, -1 = mark below
  end;
  TCompArray = array of TComp;
  TPointArray = array of TPoint;

function DefaultOcrOptions: TOcrOptions;
begin
  Result.AutoThreshold := True;
  Result.Threshold := 128;
  Result.Polarity := polAuto;
  Result.MergeParts := True;
  Result.MinArea := 4;
  Result.SpaceRatio := 0.4;
  Result.WholeImage := False;
  Result.ThaiMarks := False;
end;

function OtsuThreshold(const Hist: array of Integer; Total: Integer): Integer;
var
  t: Integer;
  Sum, SumB, WB, WF, MB, MF, Between, MaxBetween: Double;
begin
  Result := 128;
  Sum := 0;
  for t := 0 to 255 do
    Sum := Sum + t * Hist[t];
  SumB := 0;
  WB := 0;
  MaxBetween := -1;
  for t := 0 to 255 do
  begin
    WB := WB + Hist[t];
    if WB = 0 then Continue;
    WF := Total - WB;
    if WF = 0 then Break;
    SumB := SumB + t * Hist[t];
    MB := SumB / WB;
    MF := (Sum - SumB) / WF;
    Between := WB * WF * Sqr(MB - MF);
    if Between > MaxBetween then
    begin
      MaxBetween := Between;
      Result := t;
    end;
  end;
end;

function BitmapToBinary(Bmp: TBitmap; const Opt: TOcrOptions; out UsedThreshold: Integer): TBinImage;
var
  Img: TLazIntfImage;
  Gray: array of Byte;
  Hist: array[0..255] of Integer;
  x, y, i, Dark, T: Integer;
  C: TFPColor;
  LightInk: Boolean;
begin
  Result.W := Bmp.Width;
  Result.H := Bmp.Height;
  SetLength(Result.Data, Result.W * Result.H);
  SetLength(Gray, Result.W * Result.H);
  UsedThreshold := Opt.Threshold;
  if Length(Gray) = 0 then Exit;

  FillChar(Hist, SizeOf(Hist), 0);
  Img := Bmp.CreateIntfImage;
  try
    for y := 0 to Result.H - 1 do
      for x := 0 to Result.W - 1 do
      begin
        C := Img.Colors[x, y];
        i := (Integer(C.Red) * 299 + Integer(C.Green) * 587 + Integer(C.Blue) * 114) div 1000 shr 8;
        Gray[y * Result.W + x] := i;
        Inc(Hist[i]);
      end;
  finally
    Img.Free;
  end;

  if Opt.AutoThreshold then
    T := OtsuThreshold(Hist, Length(Gray))
  else
    T := Opt.Threshold;
  UsedThreshold := T;

  case Opt.Polarity of
    polDarkOnLight: LightInk := False;
    polLightOnDark: LightInk := True;
  else
    // auto: the background usually covers more area than the text
    Dark := 0;
    for i := 0 to T do
      Inc(Dark, Hist[i]);
    LightInk := Dark > Length(Gray) div 2;
  end;

  for i := 0 to High(Gray) do
    if LightInk then
      Result.Data[i] := Ord(Gray[i] > T)
    else
      Result.Data[i] := Ord(Gray[i] <= T);
end;

{ ---------- Line detection ---------- }

function FindLines(const Bin: TBinImage; MinArea: Integer): TPointArray;
var
  RowInk: array of Integer;
  x, y, Start, Sum, i, n, j: Integer;
  Changed: Boolean;
  Heights: array of Integer;
  Med, GapPrev, GapNext: Integer;
begin
  Result := nil;
  SetLength(RowInk, Bin.H);
  for y := 0 to Bin.H - 1 do
  begin
    Sum := 0;
    for x := 0 to Bin.W - 1 do
      Inc(Sum, Bin.Data[y * Bin.W + x]);
    RowInk[y] := Sum;
  end;

  // runs of consecutive rows containing ink (X = top, Y = exclusive bottom)
  n := 0;
  y := 0;
  while y < Bin.H do
  begin
    if RowInk[y] > 0 then
    begin
      Start := y;
      Sum := 0;
      while (y < Bin.H) and (RowInk[y] > 0) do
      begin
        Inc(Sum, RowInk[y]);
        Inc(y);
      end;
      if Sum >= MinArea then
      begin
        SetLength(Result, n + 1);
        Result[n] := Point(Start, y);
        Inc(n);
      end;
    end
    else
      Inc(y);
  end;

  // very thin bands (Thai upper/lower vowels, tone marks) are merged into the nearest line
  repeat
    Changed := False;
    if Length(Result) < 2 then Break;
    SetLength(Heights, Length(Result));
    for i := 0 to High(Result) do
      Heights[i] := Result[i].Y - Result[i].X;
    // simple median
    for i := 1 to High(Heights) do
    begin
      Med := Heights[i];
      j := i - 1;
      while (j >= 0) and (Heights[j] > Med) do
      begin
        Heights[j + 1] := Heights[j];
        Dec(j);
      end;
      Heights[j + 1] := Med;
    end;
    // reference height = median of the "real" text bands (at least half the tallest),
    // so that many thin mark bands cannot pull the reference down
    j := 0;
    while Heights[j] < 0.5 * Heights[High(Heights)] do Inc(j);
    Med := Heights[j + (High(Heights) - j + 1) div 2];

    for i := 0 to High(Result) do
      if (Result[i].Y - Result[i].X) < 0.45 * Med then
      begin
        if i > 0 then GapPrev := Result[i].X - Result[i - 1].Y else GapPrev := MaxInt;
        if i < High(Result) then GapNext := Result[i + 1].X - Result[i].Y else GapNext := MaxInt;
        if GapPrev <= GapNext then j := i - 1 else j := i + 1;
        Result[j].X := Min(Result[j].X, Result[i].X);
        Result[j].Y := Max(Result[j].Y, Result[i].Y);
        Delete(Result, i, 1);
        Changed := True;
        Break;
      end;
  until not Changed;
end;

{ ---------- Features ---------- }

function InIds(Id: Integer; const Ids: TIntArr): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Ids) do
    if Ids[i] = Id then Exit(True);
  Result := False;
end;

function CalcFeature(const Bin: TBinImage; const Lab: TIntArr; const G: TGlyph): TFeature;
const
  SS = 4;   // supersampling per cell
var
  W, H, Side, cx, cy, sx, sy, px, py, Hits, LH: Integer;
  OffX, OffY, FX, FY: Double;
begin
  SetLength(Result, FEAT_DIM);
  W := G.R.Right - G.R.Left;
  H := G.R.Bottom - G.R.Top;
  Side := Max(W, H);
  if Side <= 0 then Exit;
  // center the symbol inside a square to keep its aspect ratio
  OffX := (Side - W) / 2;
  OffY := (Side - H) / 2;
  for cy := 0 to GRID - 1 do
    for cx := 0 to GRID - 1 do
    begin
      Hits := 0;
      for sy := 0 to SS - 1 do
        for sx := 0 to SS - 1 do
        begin
          FX := (cx * SS + sx + 0.5) * Side / (GRID * SS) - OffX;
          FY := (cy * SS + sy + 0.5) * Side / (GRID * SS) - OffY;
          if (FX < 0) or (FY < 0) then Continue;
          px := G.R.Left + Trunc(FX);
          py := G.R.Top + Trunc(FY);
          if (px >= G.R.Right) or (py >= G.R.Bottom) then Continue;
          if (Bin.Data[py * Bin.W + px] = 1) and InIds(Lab[py * Bin.W + px], G.Ids) then
            Inc(Hits);
        end;
      Result[cy * GRID + cx] := Hits / (SS * SS);
    end;
  LH := Max(1, G.LineBottom - G.LineTop);
  Result[GRID * GRID] := POS_WEIGHT * H / LH;
  Result[GRID * GRID + 1] := POS_WEIGHT * ((G.R.Top + G.R.Bottom) / 2 - G.LineTop) / LH;
end;

function ShiftFeature(const F: TFeature; DX, DY: Integer): TFeature;
var
  x, y, sx, sy, i: Integer;
begin
  SetLength(Result, Length(F));
  for y := 0 to GRID - 1 do
    for x := 0 to GRID - 1 do
    begin
      sx := x - DX;
      sy := y - DY;
      if (sx >= 0) and (sx < GRID) and (sy >= 0) and (sy < GRID) then
        Result[y * GRID + x] := F[sy * GRID + sx]
      else
        Result[y * GRID + x] := 0;
    end;
  for i := GRID * GRID to High(F) do
    Result[i] := F[i];
end;

{ ---------- Symbol segmentation ---------- }

function SegmentGlyphs(const Bin: TBinImage; const Opt: TOcrOptions): TGlyphArray;
var
  Lab: TIntArr;
begin
  Result := SegmentGlyphsEx(Bin, Opt, Lab);
end;

function SegmentGlyphsEx(const Bin: TBinImage; const Opt: TOcrOptions; out Lab: TIntArr): TGlyphArray;
var
  Stack: TIntArr;
  Lines: TPointArray;
  Comps: TCompArray;
  NextId, LineIdx, NG, i, j, k, x, y, p, q, px, py, dx, dy, nx, ny, SP, Ov: Integer;
  LH, CW, CH, TW, THt, HGap, VGap, Score, Best, BestScore: Integer;
  CY: Double;
  C, Tmp: TComp;
  Changed: Boolean;

  procedure SortInts(var A: TIntArr);
  var
    a1, b1, v: Integer;
  begin
    for a1 := 1 to High(A) do
    begin
      v := A[a1];
      b1 := a1 - 1;
      while (b1 >= 0) and (A[b1] > v) do
      begin
        A[b1 + 1] := A[b1];
        Dec(b1);
      end;
      A[b1 + 1] := v;
    end;
  end;

  // Thai mode: find the middle zone (where consonant bodies are) and mark
  // pieces that lie completely above or below it as vowel / tone marks
  procedure ClassifyZones;
  var
    Tops, Bots: TIntArr;
    m, n, MidTop, MidBot, Tol: Integer;
  begin
    SetLength(Tops, Length(Comps));
    SetLength(Bots, Length(Comps));
    n := 0;
    for m := 0 to High(Comps) do
      if Comps[m].B - Comps[m].T >= 0.3 * LH then
      begin
        Tops[n] := Comps[m].T;
        Bots[n] := Comps[m].B;
        Inc(n);
      end;
    if n = 0 then
    begin
      for m := 0 to High(Comps) do
        Comps[m].Zone := 0;
      Exit;
    end;
    SetLength(Tops, n);
    SetLength(Bots, n);
    SortInts(Tops);
    SortInts(Bots);
    MidTop := Tops[n div 2];
    MidBot := Bots[n div 2];
    Tol := Max(1, Round(0.1 * (MidBot - MidTop)));
    n := MidBot - MidTop;
    for m := 0 to High(Comps) do
      if (Comps[m].B <= MidTop + Tol) or
         // small piece whose centre is above the body zone (some fonts place tone marks low)
         ((Comps[m].B - Comps[m].T <= 0.45 * n) and (Comps[m].R - Comps[m].L <= 0.7 * n) and
          ((Comps[m].T + Comps[m].B) / 2 < MidTop)) then
        Comps[m].Zone := 1
      else if (Comps[m].T >= MidBot - Tol) or
         ((Comps[m].B - Comps[m].T <= 0.45 * n) and (Comps[m].R - Comps[m].L <= 0.7 * n) and
          ((Comps[m].T + Comps[m].B) / 2 > MidBot)) then
        Comps[m].Zone := -1
      else
        Comps[m].Zone := 0;
  end;

  // Thai mode: put every mark right after its base consonant, in Unicode order:
  // base, lower vowel, upper vowel, tone mark (marks closer to the base come first)
  procedure OrderThaiMarks;
  var
    BaseOf, Keys, Idx: TIntArr;
    Sorted: TCompArray;
    m, b, n, Ovl, BestOv, BestGap, Gap, a1, b1, kv, iv: Integer;
  begin
    SetLength(BaseOf, Length(Comps));
    for m := 0 to High(Comps) do
    begin
      BaseOf[m] := -1;
      if Comps[m].Zone = 0 then Continue;
      BestOv := 0;
      BestGap := MaxInt;
      for b := 0 to High(Comps) do
      begin
        if Comps[b].Zone <> 0 then Continue;
        Ovl := Min(Comps[m].R, Comps[b].R) - Max(Comps[m].L, Comps[b].L);
        if Ovl > BestOv then
        begin
          BestOv := Ovl;
          BaseOf[m] := b;
          BestGap := 0;
        end
        else if (BestOv = 0) and (Ovl <= 0) and (-Ovl < BestGap) then
        begin
          BestGap := -Ovl;
          BaseOf[m] := b;
        end;
      end;
    end;
    SetLength(Sorted, Length(Comps));
    n := 0;
    for m := 0 to High(Comps) do
    begin
      if (Comps[m].Zone <> 0) and (BaseOf[m] >= 0) then Continue;
      Sorted[n] := Comps[m];
      Inc(n);
      if Comps[m].Zone <> 0 then Continue;
      // marks of this base: below first, then above, each by distance from the base
      Idx := nil;
      Keys := nil;
      for b := 0 to High(Comps) do
        if BaseOf[b] = m then
        begin
          SetLength(Idx, Length(Idx) + 1);
          SetLength(Keys, Length(Keys) + 1);
          Idx[High(Idx)] := b;
          if Comps[b].Zone < 0 then
            Keys[High(Keys)] := Comps[b].T - Comps[m].B
          else
            Keys[High(Keys)] := 100000 + Comps[m].T - Comps[b].B;
        end;
      for a1 := 1 to High(Keys) do
      begin
        kv := Keys[a1];
        iv := Idx[a1];
        b1 := a1 - 1;
        while (b1 >= 0) and (Keys[b1] > kv) do
        begin
          Keys[b1 + 1] := Keys[b1];
          Idx[b1 + 1] := Idx[b1];
          Dec(b1);
        end;
        Keys[b1 + 1] := kv;
        Idx[b1 + 1] := iv;
      end;
      for a1 := 0 to High(Idx) do
      begin
        Sorted[n] := Comps[Idx[a1]];
        Inc(n);
      end;
    end;
    SetLength(Sorted, n);
    Comps := Sorted;
  end;

  procedure Push(Idx: Integer);
  begin
    if SP >= Length(Stack) then
      SetLength(Stack, Length(Stack) * 2 + 64);
    Stack[SP] := Idx;
    Inc(SP);
  end;

  // merge component Src into Dst and remove Src
  procedure MergeInto(Dst, Src: Integer);
  var
    m: Integer;
  begin
    Comps[Dst].L := Min(Comps[Dst].L, Comps[Src].L);
    Comps[Dst].R := Max(Comps[Dst].R, Comps[Src].R);
    Comps[Dst].T := Min(Comps[Dst].T, Comps[Src].T);
    Comps[Dst].B := Max(Comps[Dst].B, Comps[Src].B);
    Inc(Comps[Dst].Area, Comps[Src].Area);
    for m := 0 to High(Comps[Src].Ids) do
    begin
      SetLength(Comps[Dst].Ids, Length(Comps[Dst].Ids) + 1);
      Comps[Dst].Ids[High(Comps[Dst].Ids)] := Comps[Src].Ids[m];
    end;
    Delete(Comps, Src, 1);
  end;

begin
  Result := nil;
  Lab := nil;
  if (Bin.W = 0) or (Bin.H = 0) then Exit;
  SetLength(Lab, Bin.W * Bin.H);
  Lines := FindLines(Bin, Opt.MinArea);
  NextId := 0;
  NG := 0;
  SP := 0;

  for LineIdx := 0 to High(Lines) do
  begin
    Comps := nil;
    // 8-connected components inside the line band
    for y := Lines[LineIdx].X to Lines[LineIdx].Y - 1 do
      for x := 0 to Bin.W - 1 do
      begin
        p := y * Bin.W + x;
        if (Bin.Data[p] = 0) or (Lab[p] <> 0) then Continue;
        Inc(NextId);
        C.L := x; C.R := x + 1; C.T := y; C.B := y + 1; C.Area := 0; C.Zone := 0;
        SetLength(C.Ids, 1);
        C.Ids[0] := NextId;
        Lab[p] := NextId;
        SP := 0;
        Push(p);
        while SP > 0 do
        begin
          Dec(SP);
          q := Stack[SP];
          px := q mod Bin.W;
          py := q div Bin.W;
          Inc(C.Area);
          if px < C.L then C.L := px;
          if px + 1 > C.R then C.R := px + 1;
          if py < C.T then C.T := py;
          if py + 1 > C.B then C.B := py + 1;
          for dy := -1 to 1 do
            for dx := -1 to 1 do
            begin
              nx := px + dx;
              ny := py + dy;
              if (nx < 0) or (nx >= Bin.W) or (ny < Lines[LineIdx].X) or (ny >= Lines[LineIdx].Y) then
                Continue;
              q := ny * Bin.W + nx;
              if (Bin.Data[q] = 1) and (Lab[q] = 0) then
              begin
                Lab[q] := NextId;
                Push(q);
              end;
            end;
        end;
        SetLength(Comps, Length(Comps) + 1);
        Comps[High(Comps)] := C;
        C.Ids := nil;
      end;

    LH := Max(1, Lines[LineIdx].Y - Lines[LineIdx].X);
    if Opt.ThaiMarks then
    begin
      ClassifyZones;
      // Thai THO THAN: its bottom stroke is wide and centred under the body
      // (lower vowels sit on the right and are narrower) -> join it to the body
      repeat
        Changed := False;
        for i := 0 to High(Comps) do
        begin
          if Comps[i].Zone <> -1 then Continue;
          for j := 0 to High(Comps) do
          begin
            if (j = i) or (Comps[j].Zone <> 0) then Continue;
            TW := Comps[j].R - Comps[j].L;
            if TW <= 0 then Continue;
            CY := ((Comps[i].L + Comps[i].R) / 2 - Comps[j].L) / TW;   // relative centre
            if (Comps[i].R - Comps[i].L >= 0.75 * TW) and (CY > 0.25) and (CY < 0.55) and
               (Comps[i].T - Comps[j].B <= Max(2, LH div 10)) then
            begin
              MergeInto(j, i);
              Changed := True;
              Break;
            end;
          end;
          if Changed then Break;
        end;
      until not Changed;
    end;

    // merge components that overlap horizontally (dot of i, Thai upper/lower vowels)
    if Opt.MergeParts or Opt.ThaiMarks then
      repeat
        Changed := False;
        for i := 0 to High(Comps) do
        begin
          for j := i + 1 to High(Comps) do
          begin
            // Thai mode: vowel and tone marks stay separate symbols
            if Opt.ThaiMarks and ((Comps[i].Zone <> 0) or (Comps[j].Zone <> 0)) then Continue;
            Ov := Min(Comps[i].R, Comps[j].R) - Max(Comps[i].L, Comps[j].L);
            if (Ov > 0) and (Ov >= 0.5 * Min(Comps[i].R - Comps[i].L, Comps[j].R - Comps[j].L)) then
            begin
              MergeInto(i, j);
              Changed := True;
              Break;
            end;
          end;
          if Changed then Break;
        end;
      until not Changed;

    // attach small round marks that sit just above or below a symbol but beside it,
    // e.g. the dot of i/j in script fonts (Segoe Script, Segoe Print)
    if Opt.MergeParts and not Opt.ThaiMarks then
    begin
      repeat
        Changed := False;
        for i := 0 to High(Comps) do
        begin
          CW := Comps[i].R - Comps[i].L;
          CH := Comps[i].B - Comps[i].T;
          // only small, roughly round pieces (not apostrophes or dashes in the middle)
          if (CW > 0.3 * LH) or (CH > 0.3 * LH) or (CH > 1.8 * CW + 1) then Continue;
          CY := (Comps[i].T + Comps[i].B) / 2;
          Best := -1;
          BestScore := MaxInt;
          for j := 0 to High(Comps) do
          begin
            if j = i then Continue;
            TW := Comps[j].R - Comps[j].L;
            THt := Comps[j].B - Comps[j].T;
            if (TW <= 0.3 * LH) and (THt <= 0.3 * LH) then Continue;   // target must be a real symbol
            // only marks clearly ABOVE the symbol (with a gap): commas and periods sit on
            // the baseline next to a letter and must stay separate
            if not ((Comps[i].B <= Comps[j].T) and (CY < Comps[j].T)) then Continue;
            HGap := Max(0, Max(Comps[i].L, Comps[j].L) - Min(Comps[i].R, Comps[j].R));
            if HGap > Max(2, Round(0.12 * LH)) then Continue;
            VGap := Comps[j].T - Comps[i].B;
            if VGap > 0.5 * LH then Continue;
            Score := HGap * 4 + VGap;
            if Score < BestScore then
            begin
              BestScore := Score;
              Best := j;
            end;
          end;
          if Best >= 0 then
          begin
            MergeInto(Best, i);
            Changed := True;
            Break;
          end;
        end;
      until not Changed;
    end;

    // sort left to right
    for i := 1 to High(Comps) do
    begin
      Tmp := Comps[i];
      j := i - 1;
      while (j >= 0) and (Comps[j].L > Tmp.L) do
      begin
        Comps[j + 1] := Comps[j];
        Dec(j);
      end;
      Comps[j + 1] := Tmp;
    end;
    if Opt.ThaiMarks then
      OrderThaiMarks;

    for i := 0 to High(Comps) do
    begin
      if Comps[i].Area < Opt.MinArea then Continue;
      SetLength(Result, NG + 1);
      Result[NG].R := Rect(Comps[i].L, Comps[i].T, Comps[i].R, Comps[i].B);
      Result[NG].Line := LineIdx;
      Result[NG].LineTop := Lines[LineIdx].X;
      Result[NG].LineBottom := Lines[LineIdx].Y;
      Result[NG].Ids := Comps[i].Ids;
      Result[NG].Text := '';
      Result[NG].Conf := 0;
      Result[NG].Feat := CalcFeature(Bin, Lab, Result[NG]);
      Inc(NG);
    end;
  end;

  // whole-image mode: merge every symbol into one (a character or a whole word)
  if Opt.WholeImage and (NG > 0) then
  begin
    for i := 1 to NG - 1 do
    begin
      Result[0].R.Left := Min(Result[0].R.Left, Result[i].R.Left);
      Result[0].R.Top := Min(Result[0].R.Top, Result[i].R.Top);
      Result[0].R.Right := Max(Result[0].R.Right, Result[i].R.Right);
      Result[0].R.Bottom := Max(Result[0].R.Bottom, Result[i].R.Bottom);
      for k := 0 to High(Result[i].Ids) do
      begin
        SetLength(Result[0].Ids, Length(Result[0].Ids) + 1);
        Result[0].Ids[High(Result[0].Ids)] := Result[i].Ids[k];
      end;
    end;
    SetLength(Result, 1);
    Result[0].Line := 0;
    Result[0].LineTop := Result[0].R.Top;
    Result[0].LineBottom := Result[0].R.Bottom;
    Result[0].Feat := CalcFeature(Bin, Lab, Result[0]);
  end;
end;

procedure MergeGlyphs(const Bin: TBinImage; const Lab: TIntArr; var G: TGlyphArray; A, B: Integer);
var
  k: Integer;
begin
  if (A = B) or (A < 0) or (B < 0) or (A > High(G)) or (B > High(G)) then Exit;
  if Length(Lab) <> Bin.W * Bin.H then Exit;
  G[A].R.Left := Min(G[A].R.Left, G[B].R.Left);
  G[A].R.Top := Min(G[A].R.Top, G[B].R.Top);
  G[A].R.Right := Max(G[A].R.Right, G[B].R.Right);
  G[A].R.Bottom := Max(G[A].R.Bottom, G[B].R.Bottom);
  G[A].LineTop := Min(G[A].LineTop, G[B].LineTop);
  G[A].LineBottom := Max(G[A].LineBottom, G[B].LineBottom);
  for k := 0 to High(G[B].Ids) do
  begin
    SetLength(G[A].Ids, Length(G[A].Ids) + 1);
    G[A].Ids[High(G[A].Ids)] := G[B].Ids[k];
  end;
  G[A].Feat := CalcFeature(Bin, Lab, G[A]);
  RemoveGlyph(G, B);
end;

procedure RemoveGlyph(var G: TGlyphArray; Idx: Integer);
begin
  if (Idx < 0) or (Idx > High(G)) then Exit;
  Delete(G, Idx, 1);
end;

{ ---------- Labels / text ---------- }

function IsCombiningMark(CP: Cardinal): Boolean;
begin
  case CP of
    $0300..$036F,           // Latin combining diacritics
    $0E31, $0E34..$0E3A,    // Thai mai han-akat, upper and lower vowels, phinthu
    $0E47..$0E4E:           // Thai maitaikhu, tone marks, thanthakhat, etc.
      Result := True;
  else
    Result := False;
  end;
end;

function TokenizeLabels(const S: string; SplitSpace, MergeCombining: Boolean): TStringArr;
var
  n, Len: Integer;
  P, PEnd: PChar;
  CP: Cardinal;
  Ch, Tok: string;
  i: Integer;

  procedure Add(const T: string);
  begin
    SetLength(Result, n + 1);
    Result[n] := T;
    Inc(n);
  end;

begin
  Result := nil;
  n := 0;
  if SplitSpace then
  begin
    Tok := '';
    for i := 1 to Length(S) do
      if S[i] in [' ', #9, #10, #13] then
      begin
        if Tok <> '' then Add(Tok);
        Tok := '';
      end
      else
        Tok := Tok + S[i];
    if Tok <> '' then Add(Tok);
    Exit;
  end;

  if S = '' then Exit;
  P := PChar(S);
  PEnd := P + Length(S);
  while P < PEnd do
  begin
    CP := UTF8CodepointToUnicode(P, Len);
    if Len < 1 then Len := 1;
    SetString(Ch, P, Len);
    if (CP = 32) or (CP = 9) or (CP = 10) or (CP = 13) or (CP = $A0) then
      // skip whitespace
    else if CP = $0E41 then
    begin
      // Thai SARA AE is drawn as two SARA E side by side
      Add(SARA_E);
      Add(SARA_E);
    end
    else if (CP = $0E0D) and not MergeCombining then
    begin
      // Thai YO YING: body + separate bottom stroke
      Add(YO_YING);
      Add(TAIL_YO_YING);
    end
    else if CP = $0E33 then
    begin
      // Thai SARA AM = NIKHAHIT (sits on the previous consonant) + SARA AA (separate symbol)
      if MergeCombining and (n > 0) then
        Result[n - 1] := Result[n - 1] + NIKHAHIT
      else
        Add(NIKHAHIT);
      Add(SARA_AA);
    end
    else if MergeCombining and IsCombiningMark(CP) and (n > 0) then
      Result[n - 1] := Result[n - 1] + Ch
    else
      Add(Ch);
    Inc(P, Len);
  end;
end;

function GlyphsToText(const G: TGlyphArray; const Opt: TOcrOptions): string;
var
  Gaps, Sorted: TIntArr;
  i, j, k, s, PrevRight, LineStart, LH, Med, Tmp: Integer;
  Thr: Double;
begin
  Result := '';
  // gap to the previous symbol on the same line
  SetLength(Gaps, Length(G));
  PrevRight := 0;
  for i := 0 to High(G) do
  begin
    if (i = 0) or (G[i].Line <> G[i - 1].Line) then
    begin
      Gaps[i] := -MaxInt;
      PrevRight := G[i].R.Right;
    end
    else
    begin
      Gaps[i] := G[i].R.Left - PrevRight;
      PrevRight := Max(PrevRight, G[i].R.Right);
    end;
  end;

  i := 0;
  while i <= High(G) do
  begin
    LineStart := i;
    while (i + 1 <= High(G)) and (G[i + 1].Line = G[LineStart].Line) do
      Inc(i);
    // adaptive space threshold: more than 2x the typical gap between symbols,
    // but never more than SpaceRatio * line height
    LH := G[LineStart].LineBottom - G[LineStart].LineTop;
    SetLength(Sorted, i - LineStart);
    for j := LineStart + 1 to i do
      Sorted[j - LineStart - 1] := Gaps[j];
    for j := 1 to High(Sorted) do
    begin
      Tmp := Sorted[j];
      k := j - 1;
      while (k >= 0) and (Sorted[k] > Tmp) do
      begin
        Sorted[k + 1] := Sorted[k];
        Dec(k);
      end;
      Sorted[k + 1] := Tmp;
    end;
    if Length(Sorted) > 0 then Med := Sorted[Length(Sorted) div 2] else Med := 0;
    Thr := Min(Opt.SpaceRatio * LH, Max(2.0 * Med, 0.12 * LH));

    if LineStart > 0 then
      Result := Result + LineEnding;
    for s := LineStart to i do
    begin
      if (s > LineStart) and (Gaps[s] > Thr) then
        Result := Result + ' ';
      Result := Result + G[s].Text;
    end;
    Inc(i);
  end;
  // SARA AM with a tone mark, e.g. NAM: the tone mark is read between the two parts
  for i := $48 to $4B do   // U+0E48..U+0E4B tone marks
    Result := StringReplace(Result, NIKHAHIT + #$E0#$B9 + Chr($80 + i - $40) + SARA_AA,
      #$E0#$B9 + Chr($80 + i - $40) + SARA_AM, [rfReplaceAll]);
  Result := StringReplace(Result, NIKHAHIT + SARA_AA, SARA_AM, [rfReplaceAll]);
  Result := StringReplace(Result, SARA_E + SARA_E, SARA_AE, [rfReplaceAll]);
  Result := StringReplace(Result, TAIL_YO_YING, '', [rfReplaceAll]);
end;

end.

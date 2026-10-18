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
function ShiftFeature(const F: TFeature; DX, DY: Integer): TFeature;
function IsCombiningMark(CP: Cardinal): Boolean;
function TokenizeLabels(const S: string; SplitSpace, MergeCombining: Boolean): TStringArr;
function GlyphsToText(const G: TGlyphArray; const Opt: TOcrOptions): string;

implementation

const
  NIKHAHIT = #$E0#$B9#$8D;   // U+0E4D
  SARA_AA = #$E0#$B8#$B2;    // U+0E32
  SARA_AM = #$E0#$B8#$B3;    // U+0E33

type
  TComp = record
    L, T, R, B: Integer;
    Area: Integer;
    Ids: TIntArr;
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
    Med := Heights[Length(Heights) div 2];

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
  Lab, Stack: TIntArr;
  Lines: TPointArray;
  Comps: TCompArray;
  NextId, LineIdx, NG, i, j, k, x, y, p, q, px, py, dx, dy, nx, ny, SP, Ov: Integer;
  C, Tmp: TComp;
  Changed: Boolean;

  procedure Push(Idx: Integer);
  begin
    if SP >= Length(Stack) then
      SetLength(Stack, Length(Stack) * 2 + 64);
    Stack[SP] := Idx;
    Inc(SP);
  end;

begin
  Result := nil;
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
        C.L := x; C.R := x + 1; C.T := y; C.B := y + 1; C.Area := 0;
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

    // merge components that overlap horizontally (dot of i, Thai upper/lower vowels)
    if Opt.MergeParts then
      repeat
        Changed := False;
        for i := 0 to High(Comps) do
        begin
          for j := i + 1 to High(Comps) do
          begin
            Ov := Min(Comps[i].R, Comps[j].R) - Max(Comps[i].L, Comps[j].L);
            if (Ov > 0) and (Ov >= 0.5 * Min(Comps[i].R - Comps[i].L, Comps[j].R - Comps[j].L)) then
            begin
              Comps[i].L := Min(Comps[i].L, Comps[j].L);
              Comps[i].R := Max(Comps[i].R, Comps[j].R);
              Comps[i].T := Min(Comps[i].T, Comps[j].T);
              Comps[i].B := Max(Comps[i].B, Comps[j].B);
              Inc(Comps[i].Area, Comps[j].Area);
              for k := 0 to High(Comps[j].Ids) do
              begin
                SetLength(Comps[i].Ids, Length(Comps[i].Ids) + 1);
                Comps[i].Ids[High(Comps[i].Ids)] := Comps[j].Ids[k];
              end;
              Delete(Comps, j, 1);
              Changed := True;
              Break;
            end;
          end;
          if Changed then Break;
        end;
      until not Changed;

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
    else if MergeCombining and (CP = $0E33) then
    begin
      // Thai SARA AM = NIKHAHIT (sits on the previous consonant) + SARA AA (separate symbol)
      if n > 0 then
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
  Result := StringReplace(Result, NIKHAHIT + SARA_AA, SARA_AM, [rfReplaceAll]);
end;

end.

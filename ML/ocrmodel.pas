unit OcrModel;

{ Symbol learning model:
  - stores samples (feature vector + label)
  - classifiers: MLP neural network (1 hidden layer, tanh + softmax, SGD),
    k-Nearest Neighbors, Nearest Centroid and an ensemble vote of all of them
  - saves/loads as a text file (*.ocrm) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, OcrEngine;

type
  TSample = record
    Cls: Integer;
    Feat: TFeature;
  end;

  TClassifier = (clsMLP, clsKNN, clsCentroid, clsEnsemble);

const
  CLASSIFIER_NAMES: array[TClassifier] of string =
    ('MLP neural network', 'k-Nearest Neighbors', 'Nearest centroid', 'Ensemble vote');

type
  // return False to stop training
  TTrainProgress = function(Epoch, Total: Integer; Loss, Acc: Single): Boolean of object;

  { TNeuralNet }

  TNeuralNet = class
  public
    NIn, NHid, NOut: Integer;
    W1, W2: TFeature;   // weights, the bias is stored at the end of each row
    procedure Init(AIn, AHid, AOut: Integer);
    procedure Forward(const X: TFeature; var H, O: TFeature);
    function TrainSample(const X: TFeature; Target: Integer; LR: Single;
      var H, O, DH: TFeature): Single;
    procedure Reset;
  end;

  { TOcrModel }

  TOcrModel = class
  private
    FClasses: TStringList;
    FSamples: array of TSample;
    FNet: TNeuralNet;
    FNetClassCount: Integer;
    FCentroids: array of TFeature;
    FCentroidsValid: Boolean;
    procedure BuildCentroids;
    function GetClassCount: Integer;
    function GetSampleCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function ClassIndex(const S: string; AutoAdd: Boolean): Integer;
    procedure AddSample(const Lbl: string; const F: TFeature);
    procedure DeleteClass(Idx: Integer);
    function ClassSampleCount(Idx: Integer): Integer;
    // sample inspection / editing
    function SampleClass(Idx: Integer): Integer;
    function SampleFeature(Idx: Integer): TFeature;
    procedure DeleteSamples(const Idx: TIntArr);
    procedure SetSampleLabel(Idx: Integer; const Lbl: string);
    procedure RenameClass(Idx: Integer; const NewName: string);
    procedure RemoveEmptyClasses;
    function FindSuspicious(Margin: Single; out Predicted: TIntArr): Integer;
    function NetReady: Boolean;
    function Train(Epochs, Hidden: Integer; LR: Single; Augment: Boolean;
      Progress: TTrainProgress): Single;
    function PredictNN(const F: TFeature; out Conf: Single): string;
    function PredictKNN(const F: TFeature; K: Integer; out Conf: Single): string;
    function PredictCentroid(const F: TFeature; out Conf: Single): string;
    function PredictEnsemble(const F: TFeature; K: Integer; out Conf: Single): string;
    function Predict(const F: TFeature; Method: TClassifier; K: Integer; out Conf: Single): string;
    procedure SaveToFile(const FileName: string);
    procedure LoadFromFile(const FileName: string);
    property Classes: TStringList read FClasses;
    property ClassCount: Integer read GetClassCount;
    property SampleCount: Integer read GetSampleCount;
  end;

implementation

var
  FS: TFormatSettings;

function ArgMax(const A: TFeature): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to High(A) do
    if A[i] > A[Result] then Result := i;
end;

{ TNeuralNet }

procedure TNeuralNet.Init(AIn, AHid, AOut: Integer);
var
  i, j: Integer;
  Lim: Single;
begin
  NIn := AIn;
  NHid := AHid;
  NOut := AOut;
  SetLength(W1, NHid * (NIn + 1));
  SetLength(W2, NOut * (NHid + 1));
  // Xavier initialization
  Lim := Sqrt(6 / (NIn + NHid));
  for j := 0 to NHid - 1 do
  begin
    for i := 0 to NIn - 1 do
      W1[j * (NIn + 1) + i] := (Random * 2 - 1) * Lim;
    W1[j * (NIn + 1) + NIn] := 0;
  end;
  Lim := Sqrt(6 / (NHid + NOut));
  for j := 0 to NOut - 1 do
  begin
    for i := 0 to NHid - 1 do
      W2[j * (NHid + 1) + i] := (Random * 2 - 1) * Lim;
    W2[j * (NHid + 1) + NHid] := 0;
  end;
end;

procedure TNeuralNet.Reset;
begin
  NIn := 0;
  NHid := 0;
  NOut := 0;
  W1 := nil;
  W2 := nil;
end;

procedure TNeuralNet.Forward(const X: TFeature; var H, O: TFeature);
var
  i, j, Base: Integer;
  S, Mx, Sum: Single;
begin
  if Length(H) <> NHid then SetLength(H, NHid);
  if Length(O) <> NOut then SetLength(O, NOut);
  for j := 0 to NHid - 1 do
  begin
    Base := j * (NIn + 1);
    S := W1[Base + NIn];
    for i := 0 to NIn - 1 do
      S := S + W1[Base + i] * X[i];
    H[j] := Tanh(S);
  end;
  Mx := -MaxSingle;
  for j := 0 to NOut - 1 do
  begin
    Base := j * (NHid + 1);
    S := W2[Base + NHid];
    for i := 0 to NHid - 1 do
      S := S + W2[Base + i] * H[i];
    O[j] := S;
    if S > Mx then Mx := S;
  end;
  // softmax
  Sum := 0;
  for j := 0 to NOut - 1 do
  begin
    O[j] := Exp(O[j] - Mx);
    Sum := Sum + O[j];
  end;
  for j := 0 to NOut - 1 do
    O[j] := O[j] / Sum;
end;

function TNeuralNet.TrainSample(const X: TFeature; Target: Integer; LR: Single;
  var H, O, DH: TFeature): Single;
var
  i, j, k, Base: Integer;
  G: Single;
begin
  Forward(X, H, O);
  Result := -Ln(Max(O[Target], 1e-7));   // cross-entropy
  if Length(DH) <> NHid then SetLength(DH, NHid);
  for j := 0 to NHid - 1 do
    DH[j] := 0;
  // output layer: dL/dz = O - T
  for k := 0 to NOut - 1 do
  begin
    G := O[k];
    if k = Target then G := G - 1;
    Base := k * (NHid + 1);
    for j := 0 to NHid - 1 do
    begin
      DH[j] := DH[j] + G * W2[Base + j];
      W2[Base + j] := W2[Base + j] - LR * G * H[j];
    end;
    W2[Base + NHid] := W2[Base + NHid] - LR * G;
  end;
  // hidden layer: tanh derivative = 1 - h^2
  for j := 0 to NHid - 1 do
  begin
    G := DH[j] * (1 - H[j] * H[j]);
    Base := j * (NIn + 1);
    for i := 0 to NIn - 1 do
      W1[Base + i] := W1[Base + i] - LR * G * X[i];
    W1[Base + NIn] := W1[Base + NIn] - LR * G;
  end;
end;

{ TOcrModel }

constructor TOcrModel.Create;
begin
  FClasses := TStringList.Create;
  FClasses.CaseSensitive := True;   // 'A' and 'a' are different classes
  FNet := TNeuralNet.Create;
end;

destructor TOcrModel.Destroy;
begin
  FNet.Free;
  FClasses.Free;
  inherited Destroy;
end;

procedure TOcrModel.Clear;
begin
  FClasses.Clear;
  FSamples := nil;
  FNet.Reset;
  FNetClassCount := 0;
  FCentroidsValid := False;
end;

function TOcrModel.GetClassCount: Integer;
begin
  Result := FClasses.Count;
end;

function TOcrModel.GetSampleCount: Integer;
begin
  Result := Length(FSamples);
end;

function TOcrModel.ClassIndex(const S: string; AutoAdd: Boolean): Integer;
begin
  Result := FClasses.IndexOf(S);
  if (Result < 0) and AutoAdd then
    Result := FClasses.Add(S);
end;

procedure TOcrModel.AddSample(const Lbl: string; const F: TFeature);
var
  n: Integer;
begin
  n := Length(FSamples);
  SetLength(FSamples, n + 1);
  FSamples[n].Cls := ClassIndex(Lbl, True);
  FSamples[n].Feat := Copy(F);
  FCentroidsValid := False;
end;

procedure TOcrModel.DeleteClass(Idx: Integer);
var
  i, n: Integer;
begin
  if (Idx < 0) or (Idx >= FClasses.Count) then Exit;
  n := 0;
  for i := 0 to High(FSamples) do
    if FSamples[i].Cls <> Idx then
    begin
      FSamples[n] := FSamples[i];
      if FSamples[n].Cls > Idx then Dec(FSamples[n].Cls);
      Inc(n);
    end;
  SetLength(FSamples, n);
  FClasses.Delete(Idx);
  FNet.Reset;          // class count changed, the network must be retrained
  FNetClassCount := 0;
  FCentroidsValid := False;
end;

function TOcrModel.ClassSampleCount(Idx: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSamples) do
    if FSamples[i].Cls = Idx then Inc(Result);
end;

function TOcrModel.NetReady: Boolean;
begin
  Result := (FNet.NIn = FEAT_DIM) and (FNetClassCount = FClasses.Count) and
    (FNet.NOut = FClasses.Count) and (FClasses.Count > 0);
end;

function TOcrModel.Train(Epochs, Hidden: Integer; LR: Single; Augment: Boolean;
  Progress: TTrainProgress): Single;
var
  Order: array of Integer;
  H, O, DH: TFeature;
  X: TFeature;
  Ep, i, j, t, n, Correct: Integer;
  Loss, CurLR: Single;
begin
  Result := 0;
  n := Length(FSamples);
  if (n = 0) or (FClasses.Count < 2) then
    raise Exception.Create('At least 2 classes are required for training');

  FNet.Init(FEAT_DIM, Hidden, FClasses.Count);
  FNetClassCount := FClasses.Count;
  SetLength(Order, n);
  for i := 0 to n - 1 do
    Order[i] := i;

  for Ep := 1 to Epochs do
  begin
    // shuffle the samples every epoch
    for i := n - 1 downto 1 do
    begin
      j := Random(i + 1);
      t := Order[i]; Order[i] := Order[j]; Order[j] := t;
    end;
    CurLR := LR / (1 + Ep * 0.01);
    Loss := 0;
    Correct := 0;
    for i := 0 to n - 1 do
    begin
      X := FSamples[Order[i]].Feat;
      if Augment and (Random(2) = 0) then
        X := ShiftFeature(X, Random(3) - 1, Random(3) - 1);
      Loss := Loss + FNet.TrainSample(X, FSamples[Order[i]].Cls, CurLR, H, O, DH);
      if ArgMax(O) = FSamples[Order[i]].Cls then Inc(Correct);
    end;
    if Assigned(Progress) and ((Ep mod 5 = 0) or (Ep = Epochs) or (Ep = 1)) then
      if not Progress(Ep, Epochs, Loss / n, Correct / n) then Break;
  end;

  // accuracy on the training set (without augmentation)
  Correct := 0;
  for i := 0 to n - 1 do
  begin
    FNet.Forward(FSamples[i].Feat, H, O);
    if ArgMax(O) = FSamples[i].Cls then Inc(Correct);
  end;
  Result := Correct / n;
end;

function TOcrModel.PredictNN(const F: TFeature; out Conf: Single): string;
var
  H, O: TFeature;
  k: Integer;
begin
  Conf := 0;
  Result := '';
  if not NetReady then Exit;
  H := nil;
  O := nil;
  FNet.Forward(F, H, O);
  k := ArgMax(O);
  Conf := O[k];
  Result := FClasses[k];
end;

function TOcrModel.PredictKNN(const F: TFeature; K: Integer; out Conf: Single): string;
var
  BestD: array of Single;
  BestC: array of Integer;
  Votes: array of Single;
  i, j, m, Cnt: Integer;
  D, Diff, Total: Single;
begin
  Result := '';
  Conf := 0;
  if Length(FSamples) = 0 then Exit;
  K := Max(1, Min(K, Length(FSamples)));
  SetLength(BestD, K);
  SetLength(BestC, K);
  for i := 0 to K - 1 do
  begin
    BestD[i] := MaxSingle;
    BestC[i] := -1;
  end;
  for i := 0 to High(FSamples) do
  begin
    D := 0;
    for j := 0 to FEAT_DIM - 1 do
    begin
      Diff := F[j] - FSamples[i].Feat[j];
      D := D + Diff * Diff;
    end;
    if D < BestD[K - 1] then
    begin
      m := K - 1;
      while (m > 0) and (BestD[m - 1] > D) do
      begin
        BestD[m] := BestD[m - 1];
        BestC[m] := BestC[m - 1];
        Dec(m);
      end;
      BestD[m] := D;
      BestC[m] := FSamples[i].Cls;
    end;
  end;
  // vote weighted by distance
  SetLength(Votes, FClasses.Count);
  Total := 0;
  Cnt := 0;
  for i := 0 to K - 1 do
    if BestC[i] >= 0 then
    begin
      Votes[BestC[i]] := Votes[BestC[i]] + 1 / (Sqrt(BestD[i]) + 0.05);
      Total := Total + 1 / (Sqrt(BestD[i]) + 0.05);
      Inc(Cnt);
    end;
  if Cnt = 0 then Exit;
  m := ArgMax(Votes);
  Result := FClasses[m];
  Conf := Votes[m] / Total;
end;

{ ---------- Sample inspection / editing ---------- }

function TOcrModel.SampleClass(Idx: Integer): Integer;
begin
  Result := FSamples[Idx].Cls;
end;

function TOcrModel.SampleFeature(Idx: Integer): TFeature;
begin
  Result := FSamples[Idx].Feat;
end;

procedure TOcrModel.DeleteSamples(const Idx: TIntArr);
var
  Del: array of Boolean;
  i, n: Integer;
begin
  if Length(Idx) = 0 then Exit;
  SetLength(Del, Length(FSamples));
  for i := 0 to High(Idx) do
    if (Idx[i] >= 0) and (Idx[i] < Length(FSamples)) then
      Del[Idx[i]] := True;
  n := 0;
  for i := 0 to High(FSamples) do
    if not Del[i] then
    begin
      FSamples[n] := FSamples[i];
      Inc(n);
    end;
  SetLength(FSamples, n);
  FCentroidsValid := False;
  RemoveEmptyClasses;
end;

procedure TOcrModel.SetSampleLabel(Idx: Integer; const Lbl: string);
begin
  if (Idx < 0) or (Idx > High(FSamples)) or (Lbl = '') then Exit;
  FSamples[Idx].Cls := ClassIndex(Lbl, True);
  FCentroidsValid := False;
  RemoveEmptyClasses;
end;

procedure TOcrModel.RenameClass(Idx: Integer; const NewName: string);
var
  Target, i: Integer;
begin
  if (Idx < 0) or (Idx >= FClasses.Count) or (NewName = '') then Exit;
  Target := FClasses.IndexOf(NewName);
  if Target = Idx then Exit;
  if Target < 0 then
    FClasses[Idx] := NewName      // plain rename, the trained network stays valid
  else
  begin
    // the name already exists: merge the two classes
    for i := 0 to High(FSamples) do
      if FSamples[i].Cls = Idx then FSamples[i].Cls := Target;
    DeleteClass(Idx);
  end;
  FCentroidsValid := False;
end;

procedure TOcrModel.RemoveEmptyClasses;
var
  i: Integer;
begin
  for i := FClasses.Count - 1 downto 0 do
    if ClassSampleCount(i) = 0 then
      DeleteClass(i);
end;

function ShapeVector(const F: TFeature): TFeature;
{ Blurred and length-normalized copy of the 16 x 16 grid. Comparing these with
  cosine similarity looks at the SHAPE and ignores stroke thickness and darkness. }
var
  x, y, dx, dy, sx, sy: Integer;
  S, W, Len: Single;
begin
  SetLength(Result, GRID * GRID);
  Len := 0;
  for y := 0 to GRID - 1 do
    for x := 0 to GRID - 1 do
    begin
      S := 0;
      for dy := -1 to 1 do
        for dx := -1 to 1 do
        begin
          sx := x + dx;
          sy := y + dy;
          if (sx < 0) or (sx >= GRID) or (sy < 0) or (sy >= GRID) then Continue;
          if (dx = 0) and (dy = 0) then W := 4
          else if (dx = 0) or (dy = 0) then W := 2
          else W := 1;
          S := S + W * Min(1.0, F[sy * GRID + sx] * 2);   // thin strokes count as ink too
        end;
      Result[y * GRID + x] := S;
      Len := Len + S * S;
    end;
  Len := Sqrt(Len);
  if Len > 0 then
    for x := 0 to High(Result) do
      Result[x] := Result[x] / Len;
end;

function TOcrModel.FindSuspicious(Margin: Single; out Predicted: TIntArr): Integer;
{ Leave-one-out check. For every sample, find the most similar OTHER sample of its own
  class and the most similar sample of any other class (cosine similarity of shapes).
  If another class is clearly more similar (by more than Margin), the sample is
  probably mislabeled. Predicted[i] = suggested class, or -1 when it looks fine.
  Samples whose class has no other sample cannot be judged and are never flagged. }
var
  V: array of TFeature;
  i, j, c, OtherCls: Integer;
  Sim, Own, Other: Single;
begin
  Result := 0;
  SetLength(Predicted, Length(FSamples));
  SetLength(V, Length(FSamples));
  for i := 0 to High(FSamples) do
    V[i] := ShapeVector(FSamples[i].Feat);
  for i := 0 to High(FSamples) do
  begin
    Predicted[i] := -1;
    Own := -1;
    Other := -1;
    OtherCls := -1;
    for j := 0 to High(FSamples) do
    begin
      if j = i then Continue;
      Sim := 0;
      for c := 0 to GRID * GRID - 1 do
        Sim := Sim + V[i][c] * V[j][c];
      if FSamples[j].Cls = FSamples[i].Cls then
      begin
        if Sim > Own then Own := Sim;
      end
      else if Sim > Other then
      begin
        Other := Sim;
        OtherCls := FSamples[j].Cls;
      end;
    end;
    if (Own >= 0) and (OtherCls >= 0) and (Other > Own + Margin) then
    begin
      Predicted[i] := OtherCls;
      Inc(Result);
    end;
  end;
end;

procedure TOcrModel.BuildCentroids;
var
  Counts: array of Integer;
  i, j, c: Integer;
begin
  SetLength(FCentroids, FClasses.Count);
  SetLength(Counts, FClasses.Count);
  for c := 0 to High(FCentroids) do
  begin
    SetLength(FCentroids[c], FEAT_DIM);
    for j := 0 to FEAT_DIM - 1 do
      FCentroids[c][j] := 0;
  end;
  for i := 0 to High(FSamples) do
  begin
    c := FSamples[i].Cls;
    Inc(Counts[c]);
    for j := 0 to FEAT_DIM - 1 do
      FCentroids[c][j] := FCentroids[c][j] + FSamples[i].Feat[j];
  end;
  for c := 0 to High(FCentroids) do
    if Counts[c] > 0 then
      for j := 0 to FEAT_DIM - 1 do
        FCentroids[c][j] := FCentroids[c][j] / Counts[c];
  FCentroidsValid := True;
end;

function TOcrModel.PredictCentroid(const F: TFeature; out Conf: Single): string;
var
  c, j, Best: Integer;
  D, Diff, D1, D2: Single;
begin
  Result := '';
  Conf := 0;
  if FClasses.Count = 0 then Exit;
  if not FCentroidsValid then BuildCentroids;
  D1 := MaxSingle;
  D2 := MaxSingle;
  Best := 0;
  for c := 0 to High(FCentroids) do
  begin
    D := 0;
    for j := 0 to FEAT_DIM - 1 do
    begin
      Diff := F[j] - FCentroids[c][j];
      D := D + Diff * Diff;
    end;
    D := Sqrt(D);
    if D < D1 then
    begin
      D2 := D1;
      D1 := D;
      Best := c;
    end
    else if D < D2 then
      D2 := D;
  end;
  Result := FClasses[Best];
  // confidence from the margin between the best and the second-best class
  if D2 >= MaxSingle then
    Conf := 1
  else
    Conf := D2 / (D1 + D2 + 1e-6);
end;

function TOcrModel.PredictEnsemble(const F: TFeature; K: Integer; out Conf: Single): string;
var
  Lbl: array[0..2] of string;
  Cf: array[0..2] of Single;
  i, j, n, BestVotes, Votes: Integer;
  BestScore, Score: Single;
begin
  n := 0;
  if NetReady then
  begin
    Lbl[n] := PredictNN(F, Cf[n]);
    Inc(n);
  end;
  Lbl[n] := PredictKNN(F, K, Cf[n]);
  Inc(n);
  Lbl[n] := PredictCentroid(F, Cf[n]);
  Inc(n);
  // majority vote, ties broken by the summed confidence
  Result := '';
  Conf := 0;
  BestVotes := 0;
  BestScore := -1;
  for i := 0 to n - 1 do
  begin
    Votes := 0;
    Score := 0;
    for j := 0 to n - 1 do
      if Lbl[j] = Lbl[i] then
      begin
        Inc(Votes);
        Score := Score + Cf[j];
      end;
    if (Votes > BestVotes) or ((Votes = BestVotes) and (Score > BestScore)) then
    begin
      BestVotes := Votes;
      BestScore := Score;
      Result := Lbl[i];
    end;
  end;
  if n > 0 then Conf := BestScore / n;
end;

function TOcrModel.Predict(const F: TFeature; Method: TClassifier; K: Integer; out Conf: Single): string;
begin
  case Method of
    clsMLP:
      if NetReady then
        Result := PredictNN(F, Conf)
      else
        Result := PredictKNN(F, K, Conf);
    clsKNN: Result := PredictKNN(F, K, Conf);
    clsCentroid: Result := PredictCentroid(F, Conf);
  else
    Result := PredictEnsemble(F, K, Conf);
  end;
end;

{ ---------- Files ---------- }

function FloatsToStr(const A: TFeature): string;
var
  i, P, L: Integer;
  T: string;
begin
  SetLength(Result, Length(A) * 12 + 16);
  P := 1;
  for i := 0 to High(A) do
  begin
    T := FloatToStrF(A[i], ffGeneral, 7, 0, FS);
    if i > 0 then T := ' ' + T;
    L := Length(T);
    while P + L - 1 > Length(Result) do
      SetLength(Result, Length(Result) * 2);
    Move(T[1], Result[P], L);
    Inc(P, L);
  end;
  SetLength(Result, P - 1);
end;

function StrToFloats(const S: string): TFeature;
var
  i, j, n: Integer;
begin
  SetLength(Result, 64);
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do Inc(i);
    if i > Length(S) then Break;
    j := i;
    while (j <= Length(S)) and (S[j] <> ' ') do Inc(j);
    if n >= Length(Result) then SetLength(Result, n * 2);
    Result[n] := StrToFloat(Copy(S, i, j - i), FS);
    Inc(n);
    i := j;
  end;
  SetLength(Result, n);
end;

procedure TOcrModel.SaveToFile(const FileName: string);
var
  SL: TStringList;
  i: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Add('LAZOCR 1');
    SL.Add('CLASSES ' + IntToStr(FClasses.Count));
    for i := 0 to FClasses.Count - 1 do
      SL.Add(FClasses[i]);
    SL.Add(Format('SAMPLES %d %d', [Length(FSamples), FEAT_DIM]));
    for i := 0 to High(FSamples) do
      SL.Add(IntToStr(FSamples[i].Cls) + ' ' + FloatsToStr(FSamples[i].Feat));
    if NetReady then
    begin
      SL.Add(Format('NET %d %d %d', [FNet.NIn, FNet.NHid, FNet.NOut]));
      SL.Add(FloatsToStr(FNet.W1));
      SL.Add(FloatsToStr(FNet.W2));
    end
    else
      SL.Add('NET 0 0 0');
    SL.SaveToFile(FileName);
  finally
    SL.Free;
  end;
end;

procedure TOcrModel.LoadFromFile(const FileName: string);
var
  SL: TStringList;
  LineNo, i, n, Dim: Integer;
  V: TFeature;

  function WordInt(const S: string; N: Integer): Integer;
  begin
    Result := StrToInt(ExtractWord(N, S, [' ']));
  end;

begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    if (SL.Count < 3) or not AnsiStartsStr('LAZOCR', SL[0]) then
      raise Exception.Create('Not a LazOCR model file');
    Clear;
    LineNo := 1;
    n := WordInt(SL[LineNo], 2);
    Inc(LineNo);
    for i := 0 to n - 1 do
    begin
      FClasses.Add(SL[LineNo]);
      Inc(LineNo);
    end;
    n := WordInt(SL[LineNo], 2);
    Dim := WordInt(SL[LineNo], 3);
    if Dim <> FEAT_DIM then
      raise Exception.CreateFmt('Feature size mismatch (%d <> %d)', [Dim, FEAT_DIM]);
    Inc(LineNo);
    SetLength(FSamples, n);
    for i := 0 to n - 1 do
    begin
      V := StrToFloats(SL[LineNo]);
      FSamples[i].Cls := Round(V[0]);
      FSamples[i].Feat := Copy(V, 1, FEAT_DIM);
      Inc(LineNo);
    end;
    if (LineNo < SL.Count) and (WordInt(SL[LineNo], 2) > 0) then
    begin
      FNet.NIn := WordInt(SL[LineNo], 2);
      FNet.NHid := WordInt(SL[LineNo], 3);
      FNet.NOut := WordInt(SL[LineNo], 4);
      FNet.W1 := StrToFloats(SL[LineNo + 1]);
      FNet.W2 := StrToFloats(SL[LineNo + 2]);
      FNetClassCount := FNet.NOut;
      if (Length(FNet.W1) <> FNet.NHid * (FNet.NIn + 1)) or
         (Length(FNet.W2) <> FNet.NOut * (FNet.NHid + 1)) then
        FNet.Reset;
    end;
  except
    Clear;
    SL.Free;
    raise;
  end;
  SL.Free;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;

end.

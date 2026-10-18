unit ModelInspector;

{ Model Inspector: view every sample stored in a model (.ocrm) as a picture,
  find samples that are probably mislabeled, and fix them
  (delete, relabel, move, rename or merge classes). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  LCLType, Math, OcrEngine, OcrModel;

type

  { TFormInspector }

  TFormInspector = class(TForm)
  private
    FModel: TOcrModel;
    FFileName: string;
    FChanged: Boolean;         // the model was modified in this window
    FUnsaved: Boolean;         // modified since the last save
    FView: TIntArr;            // sample indices currently shown
    FSelected: array of Boolean;
    FPredicted: TIntArr;       // suspected class per sample, -1 = looks fine
    FChecked: Boolean;
    FAnchor: Integer;          // FView position for Shift+click
    pnlTop, pnlLeft, pnlBottom: TPanel;
    lbClasses: TListBox;
    sbThumbs: TScrollBox;
    pbThumbs: TPaintBox;
    lblFile, lblInfo, lblHover: TLabel;
    chkSuspicious: TCheckBox;
    cbSensitivity: TComboBox;
    OpenDlg: TOpenDialog;
    SaveDlg: TSaveDialog;
    function AddButton(AParent: TWinControl; const ACaption: string; ALeft, ATop, AWidth: Integer;
      AClick: TNotifyEvent): TButton;
    procedure BuildUI;
    procedure Modified;
    procedure RunCheck;
    procedure RefreshClasses;
    procedure RefreshView;
    procedure UpdateThumbSize;
    procedure UpdateInfo;
    function ThumbAt(X, Y: Integer): Integer;
    function SelectedSamples: TIntArr;
    function SelectedClass: Integer;
    procedure OpenClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SaveAsClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure HelpClick(Sender: TObject);
    procedure ClassClick(Sender: TObject);
    procedure RenameClassClick(Sender: TObject);
    procedure DeleteClassClick(Sender: TObject);
    procedure DeleteSamplesClick(Sender: TObject);
    procedure MoveSamplesClick(Sender: TObject);
    procedure AcceptSuggestionClick(Sender: TObject);
    procedure SelectAllClick(Sender: TObject);
    procedure SuspiciousChange(Sender: TObject);
    procedure SensitivityChange(Sender: TObject);
    procedure ThumbsPaint(Sender: TObject);
    procedure ThumbsMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ThumbsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ThumbsResize(Sender: TObject);
    procedure InspectorKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure InspectorCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateFor(AOwner: TComponent; AModel: TOcrModel; const AFileName: string);
    property Changed: Boolean read FChanged;
    property FileName: string read FFileName;
  end;

{ Shows the inspector for AModel. Returns True when the model was changed.
  AFileName is the file used by "Save"; it is updated when another file is opened. }
function ShowModelInspector(AModel: TOcrModel; var AFileName: string): Boolean;

implementation

const
  TW = 66;          // thumbnail cell width
  TH = 88;          // thumbnail cell height
  PIX = 3;          // screen pixels per feature cell (16 x 3 = 48)
  // how much more similar another class must be before a sample is flagged
  MARGINS: array[0..2] of Single = (0.08, 0.05, 0.02);

  INSPECTOR_HELP =
    'MODEL INSPECTOR' + LineEnding + LineEnding +
    'Every picture is one training sample exactly as the classifier sees it (16 x 16).' + LineEnding +
    'The text under a picture is the label it was taught with.' + LineEnding + LineEnding +
    'FINDING MISTAKES' + LineEnding +
    ' - Click a class on the left to see only its samples. A sample that does not look like' + LineEnding +
    '   the others in that class was probably taught with the wrong label.' + LineEnding +
    ' - "Find mistakes" compares every sample with its most similar samples. When they' + LineEnding +
    '   belong to another class, the sample gets a red frame and the suggested label' + LineEnding +
    '   (e.g. "-> B?"). Tick "Show only suspicious" to list just those.' + LineEnding + LineEnding +
    'FIXING' + LineEnding +
    ' - Select samples: click, Ctrl+click (add), Shift+click (range), Ctrl+A (all shown).' + LineEnding +
    ' - Delete selected (Del key): removes the samples.' + LineEnding +
    ' - Change label of selected: gives the samples another label (new or existing class).' + LineEnding +
    ' - Accept suggestion: relabels selected red samples with their suggested label.' + LineEnding +
    ' - Rename class: renames a class; using an existing name merges both classes.' + LineEnding +
    ' - Delete class: removes a class and all of its samples.' + LineEnding + LineEnding +
    'FILES' + LineEnding +
    ' - Open file...: inspect another .ocrm file (it becomes the current model).' + LineEnding +
    ' - Save / Save as...: write the corrected model to a file.' + LineEnding + LineEnding +
    'After fixing samples, train the neural network again ("Start training") so it' + LineEnding +
    'forgets the wrong examples. k-NN and nearest centroid use the fixes immediately.';

function ShowModelInspector(AModel: TOcrModel; var AFileName: string): Boolean;
var
  F: TFormInspector;
begin
  F := TFormInspector.CreateFor(nil, AModel, AFileName);
  try
    F.ShowModal;
    Result := F.Changed;
    AFileName := F.FileName;
  finally
    F.Free;
  end;
end;

{ TFormInspector }

constructor TFormInspector.CreateFor(AOwner: TComponent; AModel: TOcrModel; const AFileName: string);
begin
  inherited CreateNew(AOwner);
  FModel := AModel;
  FFileName := AFileName;
  FAnchor := -1;
  BuildUI;
  RefreshClasses;
  lbClasses.ItemIndex := 0;
  RefreshView;
end;

function TFormInspector.AddButton(AParent: TWinControl; const ACaption: string;
  ALeft, ATop, AWidth: Integer; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.SetBounds(ALeft, ATop, AWidth, 30);
  Result.OnClick := AClick;
end;

procedure TFormInspector.BuildUI;
var
  L: TLabel;
  B: TButton;
begin
  Caption := 'Model Inspector - check and fix training samples';
  Width := 1100;
  Height := 720;
  Position := poMainFormCenter;
  KeyPreview := True;
  OnKeyDown := @InspectorKeyDown;
  OnCloseQuery := @InspectorCloseQuery;

  OpenDlg := TOpenDialog.Create(Self);
  OpenDlg.Title := 'Open model file';
  OpenDlg.Filter := 'LazOCR model (*.ocrm)|*.ocrm|All files (*.*)|*.*';
  SaveDlg := TSaveDialog.Create(Self);
  SaveDlg.Title := 'Save model as';
  SaveDlg.Filter := 'LazOCR model (*.ocrm)|*.ocrm';
  SaveDlg.DefaultExt := '.ocrm';
  SaveDlg.Options := SaveDlg.Options + [ofOverwritePrompt];

  // --- top: files and checking ---
  pnlTop := TPanel.Create(Self);
  pnlTop.Parent := Self;
  pnlTop.Align := alTop;
  pnlTop.Height := 70;
  pnlTop.BevelOuter := bvNone;
  AddButton(pnlTop, 'Open file...', 8, 6, 100, @OpenClick);
  AddButton(pnlTop, 'Save', 112, 6, 80, @SaveClick);
  AddButton(pnlTop, 'Save as...', 196, 6, 90, @SaveAsClick);
  B := AddButton(pnlTop, 'Find mistakes', 310, 6, 130, @CheckClick);
  B.Font.Style := [fsBold];
  chkSuspicious := TCheckBox.Create(Self);
  chkSuspicious.Parent := pnlTop;
  chkSuspicious.Caption := 'Show only suspicious';
  chkSuspicious.SetBounds(450, 12, 170, 19);
  chkSuspicious.OnChange := @SuspiciousChange;
  L := TLabel.Create(Self);
  L.Parent := pnlTop;
  L.SetBounds(630, 13, 70, 15);
  L.Caption := 'Sensitivity:';
  cbSensitivity := TComboBox.Create(Self);
  cbSensitivity.Parent := pnlTop;
  cbSensitivity.Style := csDropDownList;
  cbSensitivity.Items.Add('Strict (fewer flags)');
  cbSensitivity.Items.Add('Normal');
  cbSensitivity.Items.Add('Sensitive (more flags)');
  cbSensitivity.ItemIndex := 1;
  cbSensitivity.SetBounds(702, 9, 160, 23);
  cbSensitivity.OnChange := @SensitivityChange;
  AddButton(pnlTop, 'Help', 880, 6, 70, @HelpClick);
  lblFile := TLabel.Create(Self);
  lblFile.Parent := pnlTop;
  lblFile.SetBounds(8, 44, 1000, 15);
  lblFile.Font.Style := [fsBold];

  // --- left: classes ---
  pnlLeft := TPanel.Create(Self);
  pnlLeft.Parent := Self;
  pnlLeft.Align := alLeft;
  pnlLeft.Width := 230;
  pnlLeft.BevelOuter := bvNone;
  L := TLabel.Create(Self);
  L.Parent := pnlLeft;
  L.Align := alTop;
  L.BorderSpacing.Around := 6;
  L.Caption := 'Classes (click to filter):';
  B := AddButton(pnlLeft, 'Delete class', 8, 0, 214, @DeleteClassClick);
  B.Align := alBottom;
  B.BorderSpacing.Around := 6;
  B := AddButton(pnlLeft, 'Rename / merge class...', 8, 0, 214, @RenameClassClick);
  B.Align := alBottom;
  B.BorderSpacing.Around := 6;
  lbClasses := TListBox.Create(Self);
  lbClasses.Parent := pnlLeft;
  lbClasses.Align := alClient;
  lbClasses.BorderSpacing.Left := 6;
  lbClasses.BorderSpacing.Right := 6;
  lbClasses.Font.Height := -16;
  lbClasses.OnClick := @ClassClick;

  // --- bottom: sample actions ---
  pnlBottom := TPanel.Create(Self);
  pnlBottom.Parent := Self;
  pnlBottom.Align := alBottom;
  pnlBottom.Height := 74;
  pnlBottom.BevelOuter := bvNone;
  AddButton(pnlBottom, 'Select all (Ctrl+A)', 8, 6, 140, @SelectAllClick);
  AddButton(pnlBottom, 'Delete selected (Del)', 152, 6, 160, @DeleteSamplesClick);
  AddButton(pnlBottom, 'Change label of selected...', 316, 6, 200, @MoveSamplesClick);
  AddButton(pnlBottom, 'Accept suggestion', 520, 6, 150, @AcceptSuggestionClick);
  lblInfo := TLabel.Create(Self);
  lblInfo.Parent := pnlBottom;
  lblInfo.SetBounds(8, 42, 1000, 15);
  lblHover := TLabel.Create(Self);
  lblHover.Parent := pnlBottom;
  lblHover.SetBounds(680, 14, 400, 15);
  lblHover.Font.Color := clGrayText;

  // --- center: thumbnails ---
  sbThumbs := TScrollBox.Create(Self);
  sbThumbs.Parent := Self;
  sbThumbs.Align := alClient;
  sbThumbs.Color := clWhite;
  sbThumbs.HorzScrollBar.Visible := False;
  sbThumbs.VertScrollBar.Increment := TH;
  sbThumbs.VertScrollBar.Tracking := True;
  sbThumbs.OnResize := @ThumbsResize;
  pbThumbs := TPaintBox.Create(Self);
  pbThumbs.Parent := sbThumbs;
  pbThumbs.Align := alTop;
  pbThumbs.OnPaint := @ThumbsPaint;
  pbThumbs.OnMouseDown := @ThumbsMouseDown;
  pbThumbs.OnMouseMove := @ThumbsMouseMove;
end;

{ ---------- State ---------- }

procedure TFormInspector.Modified;
begin
  FChanged := True;
  FUnsaved := True;
  if FChecked then
    RunCheck
  else
    FPredicted := nil;
  RefreshClasses;
  RefreshView;
end;

procedure TFormInspector.RunCheck;
var
  n: Integer;
begin
  Screen.Cursor := crHourGlass;
  try
    n := FModel.FindSuspicious(MARGINS[EnsureRange(cbSensitivity.ItemIndex, 0, 2)], FPredicted);
  finally
    Screen.Cursor := crDefault;
  end;
  FChecked := True;
  lblHover.Caption := Format('Find mistakes: %d suspicious sample(s)', [n]);
end;

function TFormInspector.SelectedClass: Integer;
begin
  // list item 0 = all samples, item i = class i-1
  Result := lbClasses.ItemIndex - 1;
end;

procedure TFormInspector.RefreshClasses;
var
  Keep, i, j, Susp: Integer;
  S: string;
begin
  Keep := lbClasses.ItemIndex;
  lbClasses.Items.BeginUpdate;
  try
    lbClasses.Items.Clear;
    lbClasses.Items.Add(Format('(All samples)  %d', [FModel.SampleCount]));
    for i := 0 to FModel.ClassCount - 1 do
    begin
      S := Format('%s   (%d)', [FModel.Classes[i], FModel.ClassSampleCount(i)]);
      if FChecked and (Length(FPredicted) = FModel.SampleCount) then
      begin
        Susp := 0;
        for j := 0 to FModel.SampleCount - 1 do
          if (FModel.SampleClass(j) = i) and (FPredicted[j] >= 0) then Inc(Susp);
        if Susp > 0 then
          S := S + Format('  [%d ?]', [Susp]);
      end;
      lbClasses.Items.Add(S);
    end;
  finally
    lbClasses.Items.EndUpdate;
  end;
  if (Keep >= 0) and (Keep < lbClasses.Items.Count) then
    lbClasses.ItemIndex := Keep
  else
    lbClasses.ItemIndex := 0;
  if FFileName <> '' then
    lblFile.Caption := 'File: ' + FFileName
  else
    lblFile.Caption := 'File: (not saved)';
  if FUnsaved then
    lblFile.Caption := lblFile.Caption + '   * modified - click Save to keep the changes';
end;

procedure TFormInspector.RefreshView;
var
  Cls, i, n: Integer;
  OnlySusp: Boolean;
begin
  Cls := SelectedClass;
  OnlySusp := chkSuspicious.Checked and FChecked and (Length(FPredicted) = FModel.SampleCount);
  SetLength(FView, FModel.SampleCount);
  n := 0;
  for i := 0 to FModel.SampleCount - 1 do
  begin
    if (Cls >= 0) and (FModel.SampleClass(i) <> Cls) then Continue;
    if OnlySusp and (FPredicted[i] < 0) then Continue;
    FView[n] := i;
    Inc(n);
  end;
  SetLength(FView, n);
  SetLength(FSelected, FModel.SampleCount);
  for i := 0 to High(FSelected) do
    FSelected[i] := False;
  FAnchor := -1;
  UpdateThumbSize;
  UpdateInfo;
end;

procedure TFormInspector.UpdateInfo;
var
  i, Sel: Integer;
  NetState: string;
begin
  Sel := 0;
  for i := 0 to High(FSelected) do
    if FSelected[i] then Inc(Sel);
  if FModel.NetReady then NetState := 'trained' else NetState := 'needs training';
  lblInfo.Caption := Format('Showing %d sample(s), %d selected.   Model: %d samples, %d classes, neural network %s.',
    [Length(FView), Sel, FModel.SampleCount, FModel.ClassCount, NetState]);
  if FChanged then
    lblInfo.Caption := lblInfo.Caption + '  Train again after fixing.';
end;

function TFormInspector.SelectedSamples: TIntArr;
var
  i, n: Integer;
begin
  SetLength(Result, Length(FSelected));
  n := 0;
  for i := 0 to High(FSelected) do
    if FSelected[i] then
    begin
      Result[n] := i;
      Inc(n);
    end;
  SetLength(Result, n);
end;

{ ---------- Thumbnails ---------- }

procedure TFormInspector.UpdateThumbSize;
var
  Cols, Rows: Integer;
begin
  Cols := Max(1, sbThumbs.ClientWidth div TW);
  Rows := (Length(FView) + Cols - 1) div Cols;
  pbThumbs.Height := Max(sbThumbs.ClientHeight - 2, Rows * TH + 4);
  pbThumbs.Invalidate;
end;

procedure TFormInspector.ThumbsResize(Sender: TObject);
begin
  UpdateThumbSize;
end;


function TFormInspector.ThumbAt(X, Y: Integer): Integer;
var
  Cols, Col, Row: Integer;
begin
  Result := -1;
  Cols := Max(1, pbThumbs.Width div TW);
  Col := X div TW;
  Row := Y div TH;
  if (Col >= Cols) or (X < 0) or (Y < 0) then Exit;
  Result := Row * Cols + Col;
  if Result > High(FView) then Result := -1;
end;

procedure TFormInspector.ThumbsPaint(Sender: TObject);
var
  C: TCanvas;
  Cols, FirstRow, LastRow, p, s, X0, Y0, BX, BY, gx, gy, V, W: Integer;
  F: TFeature;
  Txt: string;
  Susp: Boolean;
begin
  C := pbThumbs.Canvas;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWhite;
  C.FillRect(pbThumbs.ClientRect);
  if Length(FView) = 0 then
  begin
    C.Font.Color := clGrayText;
    C.Font.Size := 11;
    C.TextOut(16, 16, 'No samples to show.');
    Exit;
  end;
  Cols := Max(1, pbThumbs.Width div TW);
  // draw only the rows that are visible
  FirstRow := sbThumbs.VertScrollBar.Position div TH;
  LastRow := (sbThumbs.VertScrollBar.Position + sbThumbs.ClientHeight) div TH + 1;
  for p := FirstRow * Cols to Min(High(FView), (LastRow + 1) * Cols - 1) do
  begin
    s := FView[p];
    X0 := (p mod Cols) * TW;
    Y0 := (p div Cols) * TH;
    Susp := FChecked and (s < Length(FPredicted)) and (FPredicted[s] >= 0);

    if FSelected[s] then
    begin
      C.Brush.Color := $00FFE0C0;   // light blue
      C.FillRect(X0 + 1, Y0 + 1, X0 + TW - 1, Y0 + TH - 1);
    end;

    C.Brush.Style := bsClear;
    C.Font.Size := 7;
    C.Font.Style := [];
    C.Font.Color := clGray;
    C.TextOut(X0 + 4, Y0 + 2, '#' + IntToStr(s + 1));

    // the 16 x 16 sample
    F := FModel.SampleFeature(s);
    BX := X0 + (TW - GRID * PIX) div 2;
    BY := Y0 + 14;
    C.Brush.Style := bsSolid;
    for gy := 0 to GRID - 1 do
      for gx := 0 to GRID - 1 do
      begin
        V := 255 - Round(EnsureRange(F[gy * GRID + gx], 0, 1) * 255);
        C.Brush.Color := RGBToColor(V, V, V);
        C.FillRect(BX + gx * PIX, BY + gy * PIX, BX + (gx + 1) * PIX, BY + (gy + 1) * PIX);
      end;
    C.Brush.Style := bsClear;
    if Susp then
    begin
      C.Pen.Color := clRed;
      C.Pen.Width := 2;
    end
    else
    begin
      C.Pen.Color := clSilver;
      C.Pen.Width := 1;
    end;
    C.Rectangle(BX - 2, BY - 2, BX + GRID * PIX + 2, BY + GRID * PIX + 2);
    C.Pen.Width := 1;

    // label (and suggestion)
    C.Font.Size := 9;
    C.Font.Style := [fsBold];
    C.Font.Color := clNavy;
    Txt := FModel.Classes[FModel.SampleClass(s)];
    W := C.TextWidth(Txt);
    C.TextOut(X0 + (TW - W) div 2, BY + GRID * PIX + 3, Txt);
    if Susp then
    begin
      C.Font.Color := clRed;
      C.Font.Style := [];
      Txt := '-> ' + FModel.Classes[FPredicted[s]] + '?';
      W := C.TextWidth(Txt);
      C.TextOut(X0 + (TW - W) div 2, BY + GRID * PIX + 18, Txt);
    end;
  end;
  C.Brush.Style := bsSolid;
end;

procedure TFormInspector.ThumbsMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  p, i, a, b: Integer;
begin
  p := ThumbAt(X, Y);
  if p < 0 then Exit;
  if (ssShift in Shift) and (FAnchor >= 0) then
  begin
    a := Min(FAnchor, p);
    b := Max(FAnchor, p);
    if not (ssCtrl in Shift) then
      for i := 0 to High(FSelected) do FSelected[i] := False;
    for i := a to b do FSelected[FView[i]] := True;
  end
  else if ssCtrl in Shift then
  begin
    FSelected[FView[p]] := not FSelected[FView[p]];
    FAnchor := p;
  end
  else
  begin
    for i := 0 to High(FSelected) do FSelected[i] := False;
    FSelected[FView[p]] := True;
    FAnchor := p;
  end;
  pbThumbs.Invalidate;
  UpdateInfo;
end;

procedure TFormInspector.ThumbsMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  p, s: Integer;
  S1: string;
begin
  p := ThumbAt(X, Y);
  if p < 0 then Exit;
  s := FView[p];
  S1 := Format('Sample #%d   label: %s', [s + 1, FModel.Classes[FModel.SampleClass(s)]]);
  if FChecked and (s < Length(FPredicted)) and (FPredicted[s] >= 0) then
    S1 := S1 + '   looks like: ' + FModel.Classes[FPredicted[s]];
  lblHover.Caption := S1;
end;

{ ---------- Actions ---------- }

procedure TFormInspector.ClassClick(Sender: TObject);
begin
  RefreshView;
end;

procedure TFormInspector.SensitivityChange(Sender: TObject);
begin
  if not FChecked then Exit;
  RunCheck;
  RefreshClasses;
  RefreshView;
end;

procedure TFormInspector.SuspiciousChange(Sender: TObject);
begin
  if chkSuspicious.Checked and not FChecked then
  begin
    RunCheck;
    RefreshClasses;
  end;
  RefreshView;
end;

procedure TFormInspector.CheckClick(Sender: TObject);
var
  i, n: Integer;
begin
  if FModel.SampleCount < 2 then
  begin
    MessageDlg('The model needs at least 2 samples to check.', mtInformation, [mbOK], 0);
    Exit;
  end;
  RunCheck;
  n := 0;
  for i := 0 to High(FPredicted) do
    if FPredicted[i] >= 0 then Inc(n);
  RefreshClasses;
  if n > 0 then
  begin
    chkSuspicious.Checked := True;   // also refreshes the view
    RefreshView;
    MessageDlg(Format('%d sample(s) look like a different class (red frame).' + LineEnding +
      'Check them: if the suggestion is right, select them and click "Accept suggestion";' + LineEnding +
      'if the sample is garbage, delete it; if the label is right, ignore it.', [n]),
      mtInformation, [mbOK], 0);
  end
  else
  begin
    RefreshView;
    MessageDlg('No suspicious samples found. Each sample is most similar to its own class.',
      mtInformation, [mbOK], 0);
  end;
end;

procedure TFormInspector.SelectAllClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FView) do
    FSelected[FView[i]] := True;
  pbThumbs.Invalidate;
  UpdateInfo;
end;

procedure TFormInspector.DeleteSamplesClick(Sender: TObject);
var
  Sel: TIntArr;
begin
  Sel := SelectedSamples;
  if Length(Sel) = 0 then
  begin
    MessageDlg('Select the samples to delete first (click on them).', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg(Format('Delete %d selected sample(s)?', [Length(Sel)]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  FModel.DeleteSamples(Sel);
  Modified;
end;

procedure TFormInspector.MoveSamplesClick(Sender: TObject);
var
  Sel: TIntArr;
  Lbl: string;
  i: Integer;
begin
  Sel := SelectedSamples;
  if Length(Sel) = 0 then
  begin
    MessageDlg('Select the samples to relabel first (click on them).', mtInformation, [mbOK], 0);
    Exit;
  end;
  Lbl := FModel.Classes[FModel.SampleClass(Sel[0])];
  if not InputQuery('Change label', Format('New label for %d selected sample(s):', [Length(Sel)]), Lbl) then
    Exit;
  Lbl := Trim(Lbl);
  if Lbl = '' then Exit;
  // relabel from the last index so that removing emptied classes does not shift pending ones
  for i := High(Sel) downto 0 do
    FModel.SetSampleLabel(Sel[i], Lbl);
  Modified;
end;

procedure TFormInspector.AcceptSuggestionClick(Sender: TObject);
var
  Sel: TIntArr;
  Lbls: array of string;
  i, n: Integer;
begin
  Sel := SelectedSamples;
  if not FChecked or (Length(FPredicted) <> FModel.SampleCount) then
  begin
    MessageDlg('Click "Find mistakes" first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  // remember the suggested labels by name (class indices change while relabeling)
  SetLength(Lbls, Length(Sel));
  n := 0;
  for i := 0 to High(Sel) do
    if FPredicted[Sel[i]] >= 0 then
    begin
      Lbls[i] := FModel.Classes[FPredicted[Sel[i]]];
      Inc(n);
    end;
  if n = 0 then
  begin
    MessageDlg('Select one or more red-framed samples first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg(Format('Relabel %d sample(s) with the suggested label?', [n]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  for i := High(Sel) downto 0 do
    if Lbls[i] <> '' then
      FModel.SetSampleLabel(Sel[i], Lbls[i]);
  Modified;
end;

procedure TFormInspector.RenameClassClick(Sender: TObject);
var
  Cls: Integer;
  OldName, NewName: string;
begin
  Cls := SelectedClass;
  if Cls < 0 then
  begin
    MessageDlg('Select a class in the list first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  OldName := FModel.Classes[Cls];
  NewName := OldName;
  if not InputQuery('Rename class', 'New name for class "' + OldName + '"' + LineEnding +
    '(use the name of an existing class to merge both):', NewName) then Exit;
  NewName := Trim(NewName);
  if (NewName = '') or (NewName = OldName) then Exit;
  if FModel.Classes.IndexOf(NewName) >= 0 then
    if MessageDlg(Format('Class "%s" already exists. Merge "%s" into it?', [NewName, OldName]),
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  FModel.RenameClass(Cls, NewName);
  lbClasses.ItemIndex := FModel.Classes.IndexOf(NewName) + 1;
  Modified;
end;

procedure TFormInspector.DeleteClassClick(Sender: TObject);
var
  Cls: Integer;
begin
  Cls := SelectedClass;
  if Cls < 0 then
  begin
    MessageDlg('Select a class in the list first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg(Format('Delete class "%s" and its %d sample(s)?',
    [FModel.Classes[Cls], FModel.ClassSampleCount(Cls)]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FModel.DeleteClass(Cls);
  lbClasses.ItemIndex := 0;
  Modified;
end;

procedure TFormInspector.OpenClick(Sender: TObject);
begin
  if FUnsaved then
    case MessageDlg('Save the changes to the current model first?', mtConfirmation,
      [mbYes, mbNo, mbCancel], 0) of
      mrYes: SaveClick(nil);
      mrCancel: Exit;
    end;
  if FFileName <> '' then
    OpenDlg.InitialDir := ExtractFilePath(FFileName);
  if not OpenDlg.Execute then Exit;
  try
    FModel.LoadFromFile(OpenDlg.FileName);
  except
    on E: Exception do
    begin
      MessageDlg('Cannot open the model: ' + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  FFileName := OpenDlg.FileName;
  FChanged := True;     // the program now uses this model
  FUnsaved := False;
  FChecked := False;
  FPredicted := nil;
  chkSuspicious.Checked := False;
  lbClasses.ItemIndex := 0;
  RefreshClasses;
  RefreshView;
end;

procedure TFormInspector.SaveClick(Sender: TObject);
begin
  if FFileName = '' then
  begin
    SaveAsClick(nil);
    Exit;
  end;
  FModel.SaveToFile(FFileName);
  FUnsaved := False;
  RefreshClasses;
  lblHover.Caption := 'Saved: ' + FFileName;
end;

procedure TFormInspector.SaveAsClick(Sender: TObject);
begin
  if FFileName <> '' then
  begin
    SaveDlg.InitialDir := ExtractFilePath(FFileName);
    SaveDlg.FileName := ExtractFileName(FFileName);
  end;
  if not SaveDlg.Execute then Exit;
  FFileName := SaveDlg.FileName;
  SaveClick(nil);
end;

procedure TFormInspector.HelpClick(Sender: TObject);
begin
  MessageDlg(INSPECTOR_HELP, mtInformation, [mbOK], 0);
end;

procedure TFormInspector.InspectorKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if ActiveControl is TListBox then
    if not ((Key = VK_DELETE) or ((Key = VK_A) and (ssCtrl in Shift)) or (Key = VK_F1)) then Exit;
  case Key of
    VK_DELETE:
      begin
        Key := 0;
        DeleteSamplesClick(nil);
      end;
    VK_A:
      if ssCtrl in Shift then
      begin
        Key := 0;
        SelectAllClick(nil);
      end;
    VK_F1:
      begin
        Key := 0;
        HelpClick(nil);
      end;
  end;
end;

procedure TFormInspector.InspectorCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if not FUnsaved then Exit;
  case MessageDlg('The model was changed. Save it to the file now?' + LineEnding +
    '(If you choose No, the changes are still used by the program until you exit.)',
    mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
    mrYes: SaveClick(nil);
    mrCancel: CanClose := False;
  end;
end;

end.

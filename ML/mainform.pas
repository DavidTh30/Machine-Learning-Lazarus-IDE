unit mainform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, Spin, ExtDlgs, Clipbrd, Math, LCLType, IntfGraphics, FPImage,
  OcrEngine, OcrModel, ModelInspector;

type
  TGlyphMode = (gmNone, gmLearn, gmRead);

  { TFormMain }

  TFormMain = class(TForm)
    btnAddSamples: TButton;
    btnBatchLearn: TButton;
    btnBatchRead: TButton;
    btnClearModel: TButton;
    btnCopyResult: TButton;
    btnDeleteClass: TButton;
    btnFontSample: TButton;
    btnHelp: TButton;
    btnInspect: TButton;
    btnInspect2: TButton;
    btnLoadModel: TButton;
    btnOpen: TButton;
    btnPaste: TButton;
    btnRecognize: TButton;
    btnSaveImage: TButton;
    btnSaveModel: TButton;
    btnSegment: TButton;
    btnStop: TButton;
    btnTrain: TButton;
    btnUseResult: TButton;
    cbMethod: TComboBox;
    cbPolarity: TComboBox;
    cbZoom: TComboBox;
    chkAugment: TCheckBox;
    chkAutoThreshold: TCheckBox;
    chkMergeParts: TCheckBox;
    chkReadWhole: TCheckBox;
    chkShowBinary: TCheckBox;
    chkShowBoxes: TCheckBox;
    chkSplitSpace: TCheckBox;
    chkWholeImage: TCheckBox;
    FontDialog1: TFontDialog;
    gbTrain: TGroupBox;
    lblClasses: TLabel;
    lblEpochs: TLabel;
    lblHidden: TLabel;
    lblK: TLabel;
    lblLabels: TLabel;
    lblLR: TLabel;
    lblMatch: TLabel;
    lblMethod: TLabel;
    lblMinArea: TLabel;
    lblPolarity: TLabel;
    lblResult: TLabel;
    lblSpace: TLabel;
    lblThreshold: TLabel;
    lblTrain: TLabel;
    lblZoom: TLabel;
    lbClasses: TListBox;
    memoLabels: TMemo;
    memoLog: TMemo;
    memoResult: TMemo;
    OpenBatchDialog: TOpenPictureDialog;
    OpenDialog1: TOpenDialog;
    OpenPictureDialog1: TOpenPictureDialog;
    pbGlyphs: TPaintBox;
    pbImage: TPaintBox;
    pbTrain: TProgressBar;
    pcMain: TPageControl;
    pnlCenter: TPanel;
    pnlClassButtons: TPanel;
    pnlReadButtons: TPanel;
    pnlReadTop: TPanel;
    pnlRight: TPanel;
    pnlTop: TPanel;
    SaveDialog1: TSaveDialog;
    SaveImageDialog: TSaveDialog;
    sbGlyphs: TScrollBox;
    sbImage: TScrollBox;
    seEpochs: TSpinEdit;
    seHidden: TSpinEdit;
    seK: TSpinEdit;
    seLR: TFloatSpinEdit;
    seMinArea: TSpinEdit;
    seSpace: TFloatSpinEdit;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    Splitter3: TSplitter;
    StatusBar1: TStatusBar;
    tbThreshold: TTrackBar;
    tsClasses: TTabSheet;
    tsLearn: TTabSheet;
    tsRead: TTabSheet;
    tsSettings: TTabSheet;
    procedure btnAddSamplesClick(Sender: TObject);
    procedure btnBatchLearnClick(Sender: TObject);
    procedure btnBatchReadClick(Sender: TObject);
    procedure btnClearModelClick(Sender: TObject);
    procedure btnCopyResultClick(Sender: TObject);
    procedure btnDeleteClassClick(Sender: TObject);
    procedure btnFontSampleClick(Sender: TObject);
    procedure btnHelpClick(Sender: TObject);
    procedure btnInspectClick(Sender: TObject);
    procedure btnLoadModelClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnPasteClick(Sender: TObject);
    procedure btnRecognizeClick(Sender: TObject);
    procedure btnSaveImageClick(Sender: TObject);
    procedure btnSaveModelClick(Sender: TObject);
    procedure btnSegmentClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnTrainClick(Sender: TObject);
    procedure btnUseResultClick(Sender: TObject);
    procedure cbZoomChange(Sender: TObject);
    procedure chkShowBoxesChange(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure memoLabelsChange(Sender: TObject);
    procedure pbGlyphsPaint(Sender: TObject);
    procedure pbImagePaint(Sender: TObject);
    procedure sbGlyphsResize(Sender: TObject);
    procedure SettingsChange(Sender: TObject);
  private
    FBmp: TBitmap;              // source image (white background, 24 bit)
    FBinBmp: TBitmap;           // black and white image for display
    FHasImage: Boolean;
    FBin: TBinImage;
    FThreshold: Integer;
    FGlyphs: TGlyphArray;
    FMode: TGlyphMode;
    FTokens: TStringArr;
    FModel: TOcrModel;
    FModelFile: string;
    FTraining: Boolean;
    FBusy: Boolean;
    FStopRequested: Boolean;
    FUpdating: Boolean;
    FZoom: Double;
    function GetOptions: TOcrOptions;
    function GetTokens: TStringArr;
    function LoadBitmap(const FileName: string; Bmp: TBitmap): Boolean;
    function ClassifyGlyphs(var G: TGlyphArray; Method: TClassifier): Single;
    function SelectedMethod: TClassifier;
    procedure Log(const S: string);
    procedure LoadImageFile(const FileName: string);
    procedure SetImageFromGraphic(G: TGraphic; const Source: string);
    procedure UpdateBinary;
    procedure DoSegment(Quiet, Whole: Boolean);
    procedure AlignTokens;
    procedure UpdateImageSize;
    procedure UpdateGlyphPanel;
    procedure RefreshClassList;
    procedure UpdateButtons;
    procedure ShowHelp;
    function TrainProgress(Epoch, Total: Integer; Loss, Acc: Single): Boolean;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}

const
  CELL_W = 46;
  CELL_H = 66;
  CELL_PIX = 2;
  COMPARE_ALL = 4;   // cbMethod index of "Compare all methods"
  ZOOMS: array[0..4] of Double = (0.5, 1, 1.5, 2, 3);
  DEFAULT_TEXT =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ' + LineEnding +
    'abcdefghijklmnopqrstuvwxyz' + LineEnding +
    '0123456789';

  HELP_TEXT =
    'LAZARUS OCR - LEARN AND READ TEXT FROM IMAGES' + LineEnding +
    '=============================================' + LineEnding + LineEnding +
    'The program learns what symbols look like from example images that you label,' + LineEnding +
    'then reads symbols from new images. Everything runs locally; nothing is sent anywhere.' + LineEnding + LineEnding +
    'QUICK START' + LineEnding +
    '-----------' + LineEnding +
    ' 1. Learn tab: click "Generate from font..." and pick a font. A sample image of A-Z, a-z, 0-9' + LineEnding +
    '    is created and segmented automatically.' + LineEnding +
    ' 2. Click "Add as training samples". Repeat steps 1-2 with a few more fonts.' + LineEnding +
    ' 3. Click "Start training" to train the neural network.' + LineEnding +
    ' 4. Open an image with text, go to the Read tab and click "Read text from image".' + LineEnding + LineEnding +
    'TEACHING FROM ONE IMAGE (Learn tab)' + LineEnding +
    '-----------------------------------' + LineEnding +
    ' - Open an image ("Open image...", drag and drop a file, or "Paste" from the clipboard).' + LineEnding +
    ' - Type the text that appears in the image, in reading order (left to right, top to bottom).' + LineEnding +
    '   Spaces and line breaks are ignored; each character is matched to one symbol.' + LineEnding +
    ' - Click "Segment symbols". The strip under the image shows every symbol that was found' + LineEnding +
    '   (as the 16x16 grid the classifier sees) together with the label assigned to it.' + LineEnding +
    '   The counter turns green when the number of labels equals the number of symbols.' + LineEnding +
    ' - Click "Add as training samples".' + LineEnding +
    ' - If one symbol needs a label of several characters, tick "Labels are separated by spaces"' + LineEnding +
    '   and write the labels separated by spaces, e.g.:  fi  A  B  ' + LineEnding + LineEnding +
    'TEACHING FROM MANY IMAGES AT ONCE (batch learning)' + LineEnding +
    '--------------------------------------------------' + LineEnding +
    'Use this when you have many images of the SAME character or the SAME word,' + LineEnding +
    'for example 50 scanned images of the letter "A" or 20 photos of the word "STOP".' + LineEnding +
    ' 1. Type the label in the text box (e.g.  A  or  STOP).' + LineEnding +
    ' 2. Tick "Whole image is ONE symbol" if each image should be learned as one item' + LineEnding +
    '    (recommended for whole words, logos, handwritten characters made of several strokes).' + LineEnding +
    '    Leave it unticked to segment each image into characters and match them to the label' + LineEnding +
    '    (e.g. label STOP -> S, T, O, P). Images where the count does not match are skipped.' + LineEnding +
    ' 3. Click "Learn from multiple images..." and select all the images (Ctrl/Shift + click).' + LineEnding +
    ' 4. The log lists every image that was added or skipped. Then click "Start training".' + LineEnding + LineEnding +
    'READING (Read tab)' + LineEnding +
    '------------------' + LineEnding +
    ' - "Read text from image" reads the image currently shown.' + LineEnding +
    ' - "Read multiple images..." reads many files and lists one result per file.' + LineEnding +
    ' - Tick "Read whole image as one symbol/word" when the model was taught with' + LineEnding +
    '   "Whole image is ONE symbol" (word or whole-character classification).' + LineEnding +
    ' - Boxes: blue = confident, orange = confidence below 50%.' + LineEnding +
    ' - "Correct mistakes and teach..." copies the result to the Learn tab (one label per symbol)' + LineEnding +
    '   so you can fix wrong labels and add them as new training samples.' + LineEnding + LineEnding +
    'CLASSIFIERS' + LineEnding +
    '-----------' + LineEnding +
    ' - MLP neural network: most accurate after training; needs "Start training" whenever new' + LineEnding +
    '   classes are added (falls back to k-NN if not trained).' + LineEnding +
    ' - k-Nearest Neighbors: works immediately, compares with the k most similar samples.' + LineEnding +
    ' - Nearest centroid: compares with the average shape of each class; fast and robust' + LineEnding +
    '   when there are many samples per class (good for batch-learned data).' + LineEnding +
    ' - Ensemble vote: majority vote of all the classifiers above.' + LineEnding +
    ' - Compare all methods: shows the result of every classifier side by side.' + LineEnding + LineEnding +
    'TRAINING OPTIONS' + LineEnding +
    '----------------' + LineEnding +
    ' - Epochs: number of passes over all samples (300 is usually enough).' + LineEnding +
    ' - Hidden neurons: network size; increase for many classes (e.g. 128-256 for 100+ classes).' + LineEnding +
    ' - Learning rate: step size of gradient descent (0.01 - 0.1).' + LineEnding +
    ' - Augmentation: randomly shifts samples by 1 cell so the model tolerates small offsets.' + LineEnding + LineEnding +
    'SETTINGS TAB' + LineEnding +
    '------------' + LineEnding +
    ' - Threshold: brightness level that separates ink from background (automatic = Otsu).' + LineEnding +
    ' - Text color: automatic, dark text on light background, or light text on dark background.' + LineEnding +
    ' - Merge vertically stacked parts: joins the dot of i/j and Thai upper/lower vowels and' + LineEnding +
    '   tone marks with their base character.' + LineEnding +
    ' - Ignore specks smaller than: removes noise.' + LineEnding +
    ' - Max word space: upper limit of the gap (x line height) that becomes a space.' + LineEnding +
    ' - Show black & white image: shows exactly what the segmenter sees.' + LineEnding + LineEnding +
    'CLASSES TAB' + LineEnding +
    '-----------' + LineEnding +
    'Lists every learned class with its number of samples. Select a class and click' + LineEnding +
    '"Delete selected class" to remove wrongly labelled data.' + LineEnding + LineEnding +
    'MODEL INSPECTOR (check and fix what was learned)' + LineEnding +
    '------------------------------------------------' + LineEnding +
    'Click "Inspect model..." to see every stored sample as a picture with its label.' + LineEnding +
    ' - Click a class to see only its samples; a picture that looks different was mislabeled.' + LineEnding +
    ' - "Find mistakes" marks samples that look like another class (red frame + suggestion).' + LineEnding +
    ' - Delete wrong samples, change their label, accept the suggestion, rename or merge classes.' + LineEnding +
    ' - "Open file..." inspects any .ocrm file; "Save" / "Save as..." writes the fixed model.' + LineEnding +
    'Train again afterwards so the neural network forgets the wrong examples.' + LineEnding + LineEnding +
    'MODEL FILES' + LineEnding +
    '-----------' + LineEnding +
    'The model is saved automatically to default.ocrm next to the program when you exit and' + LineEnding +
    'loaded again at start-up. Use "Save model..." / "Load model..." to keep several models.' + LineEnding + LineEnding +
    'TIPS' + LineEnding +
    '----' + LineEnding +
    ' - Teach several fonts and sizes; the more variety, the better the recognition.' + LineEnding +
    ' - Symbols that only differ by size (o/O, s/S, l/I) are hard to tell apart.' + LineEnding +
    ' - Touching characters (cursive, handwriting) cannot be split; use whole-image mode instead.' + LineEnding +
    ' - Keep images straight (not rotated) with reasonable contrast.' + LineEnding + LineEnding +
    'Keyboard: F1 = this help.';

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  Randomize;
  FBmp := TBitmap.Create;
  FBinBmp := TBitmap.Create;
  FModel := TOcrModel.Create;
  FZoom := 1;
  FontDialog1.Font.Name := 'Tahoma';
  FontDialog1.Font.Size := 28;

  FModelFile := ExtractFilePath(Application.ExeName) + 'default.ocrm';
  if FileExists(FModelFile) then
    try
      FModel.LoadFromFile(FModelFile);
      Log('Model loaded automatically: ' + FModelFile);
    except
      on E: Exception do
        Log('Could not load the default model: ' + E.Message);
    end;

  RefreshClassList;
  UpdateButtons;
  pcMain.ActivePage := tsLearn;
  Log('Getting started: open an image or click "Generate from font...", type the text, ' +
    'click "Segment symbols", "Add as training samples", then "Start training". Press F1 for help.');
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  // save the model automatically on exit
  if FModel.SampleCount > 0 then
    try
      FModel.SaveToFile(FModelFile);
    except
    end;
  FModel.Free;
  FBinBmp.Free;
  FBmp.Free;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FTraining or FBusy then
  begin
    FStopRequested := True;
    CanClose := False;
    Log('Stopping... close the program again when it has finished.');
  end;
end;

procedure TFormMain.FormDropFiles(Sender: TObject; const FileNames: array of string);
begin
  if (Length(FileNames) > 0) and not (FTraining or FBusy) then
    LoadImageFile(FileNames[0]);
end;

procedure TFormMain.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F1 then
  begin
    Key := 0;
    ShowHelp;
  end;
end;

{ ---------- General ---------- }

procedure TFormMain.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  memoLog.SelStart := Length(memoLog.Text);
end;

function TFormMain.GetOptions: TOcrOptions;
begin
  Result := DefaultOcrOptions;
  Result.AutoThreshold := chkAutoThreshold.Checked;
  Result.Threshold := tbThreshold.Position;
  Result.Polarity := TPolarity(Max(0, cbPolarity.ItemIndex));
  Result.MergeParts := chkMergeParts.Checked;
  Result.MinArea := seMinArea.Value;
  Result.SpaceRatio := seSpace.Value;
end;

function TFormMain.GetTokens: TStringArr;
var
  S: string;
begin
  if chkWholeImage.Checked then
  begin
    // the whole text is one label (a character or a word)
    S := StringReplace(memoLabels.Text, #13, ' ', [rfReplaceAll]);
    S := StringReplace(S, #10, ' ', [rfReplaceAll]);
    S := StringReplace(S, #9, ' ', [rfReplaceAll]);
    while Pos('  ', S) > 0 do
      S := StringReplace(S, '  ', ' ', [rfReplaceAll]);
    S := Trim(S);
    if S = '' then
      Result := nil
    else
    begin
      SetLength(Result, 1);
      Result[0] := S;
    end;
  end
  else
    Result := TokenizeLabels(memoLabels.Text, chkSplitSpace.Checked, chkMergeParts.Checked);
end;

function TFormMain.SelectedMethod: TClassifier;
begin
  if (cbMethod.ItemIndex < 0) or (cbMethod.ItemIndex >= COMPARE_ALL) then
    Result := clsEnsemble
  else
    Result := TClassifier(cbMethod.ItemIndex);
end;

function TFormMain.ClassifyGlyphs(var G: TGlyphArray; Method: TClassifier): Single;
var
  i: Integer;
  C: Single;
begin
  Result := 0;
  for i := 0 to High(G) do
  begin
    G[i].Text := FModel.Predict(G[i].Feat, Method, seK.Value, C);
    G[i].Conf := C;
    Result := Result + C;
  end;
  if Length(G) > 0 then
    Result := Result / Length(G);
end;

procedure TFormMain.UpdateButtons;
var
  Idle: Boolean;
begin
  Idle := not (FTraining or FBusy);
  btnTrain.Enabled := Idle;
  btnStop.Enabled := FTraining or FBusy;
  btnOpen.Enabled := Idle;
  btnPaste.Enabled := Idle;
  btnFontSample.Enabled := Idle;
  btnSaveImage.Enabled := Idle;
  btnLoadModel.Enabled := Idle;
  btnSaveModel.Enabled := Idle;
  btnClearModel.Enabled := Idle;
  btnSegment.Enabled := Idle;
  btnAddSamples.Enabled := Idle;
  btnBatchLearn.Enabled := Idle;
  btnDeleteClass.Enabled := Idle;
  btnRecognize.Enabled := Idle;
  btnBatchRead.Enabled := Idle;
  btnInspect.Enabled := Idle;
  btnInspect2.Enabled := Idle;
  btnUseResult.Enabled := Idle;
end;

procedure TFormMain.RefreshClassList;
var
  i: Integer;
  NetState: string;
begin
  lbClasses.Items.BeginUpdate;
  try
    lbClasses.Items.Clear;
    for i := 0 to FModel.ClassCount - 1 do
      lbClasses.Items.Add(Format('%s     (%d samples)', [FModel.Classes[i], FModel.ClassSampleCount(i)]));
  finally
    lbClasses.Items.EndUpdate;
  end;
  lblClasses.Caption := Format('Learned classes: %d classes, %d samples',
    [FModel.ClassCount, FModel.SampleCount]);
  if FModel.NetReady then NetState := 'trained' else NetState := 'not trained';
  StatusBar1.SimpleText := Format('Samples: %d   Classes: %d   Neural network: %s',
    [FModel.SampleCount, FModel.ClassCount, NetState]);
end;

procedure TFormMain.ShowHelp;
var
  F: TForm;
  M: TMemo;
  P: TPanel;
  B: TButton;
begin
  F := TForm.Create(nil);
  try
    F.Caption := 'Lazarus OCR - Help';
    F.Width := 760;
    F.Height := 640;
    F.Position := poMainFormCenter;
    P := TPanel.Create(F);
    P.Parent := F;
    P.Align := alBottom;
    P.Height := 44;
    P.BevelOuter := bvNone;
    B := TButton.Create(F);
    B.Parent := P;
    B.Caption := 'Close';
    B.ModalResult := mrOK;
    B.Cancel := True;
    B.Default := True;
    B.SetBounds(P.Width - 108, 8, 96, 28);
    B.Anchors := [akTop, akRight];
    M := TMemo.Create(F);
    M.Parent := F;
    M.Align := alClient;
    M.BorderSpacing.Around := 8;
    M.ReadOnly := True;
    M.ScrollBars := ssAutoVertical;
    M.WordWrap := True;
    M.Font.Name := 'Consolas';
    M.Font.Size := 10;
    M.Text := HELP_TEXT;
    M.SelStart := 0;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure TFormMain.btnHelpClick(Sender: TObject);
begin
  ShowHelp;
end;

procedure TFormMain.btnInspectClick(Sender: TObject);
var
  FN: string;
begin
  FN := FModelFile;
  if ShowModelInspector(FModel, FN) then
  begin
    Log(Format('Model changed in the inspector: %d samples, %d classes', [FModel.SampleCount, FModel.ClassCount]));
    if FModel.ClassCount >= 2 then
      Log('Click "Start training" again so the neural network learns from the corrected samples.');
    lblTrain.Caption := 'Retraining recommended';
  end;
  RefreshClassList;
end;

{ ---------- Images ---------- }

function TFormMain.LoadBitmap(const FileName: string; Bmp: TBitmap): Boolean;
var
  Pic: TPicture;
begin
  Result := False;
  Pic := TPicture.Create;
  try
    try
      Pic.LoadFromFile(FileName);
      if (Pic.Width = 0) or (Pic.Height = 0) then Exit;
      Bmp.PixelFormat := pf24bit;
      Bmp.SetSize(Pic.Width, Pic.Height);
      Bmp.Canvas.Brush.Style := bsSolid;
      Bmp.Canvas.Brush.Color := clWhite;
      Bmp.Canvas.FillRect(0, 0, Pic.Width, Pic.Height);
      Bmp.Canvas.Draw(0, 0, Pic.Graphic);
      Result := True;
    except
      on E: Exception do
        Log('Cannot open ' + ExtractFileName(FileName) + ': ' + E.Message);
    end;
  finally
    Pic.Free;
  end;
end;

procedure TFormMain.LoadImageFile(const FileName: string);
var
  Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  try
    if LoadBitmap(FileName, Bmp) then
      SetImageFromGraphic(Bmp, ExtractFileName(FileName))
    else
      MessageDlg('Cannot open the image: ' + FileName, mtError, [mbOK], 0);
  finally
    Bmp.Free;
  end;
end;

procedure TFormMain.SetImageFromGraphic(G: TGraphic; const Source: string);
begin
  if (G = nil) or (G.Width = 0) or (G.Height = 0) then Exit;
  FBmp.PixelFormat := pf24bit;
  FBmp.SetSize(G.Width, G.Height);
  FBmp.Canvas.Brush.Style := bsSolid;
  FBmp.Canvas.Brush.Color := clWhite;
  FBmp.Canvas.FillRect(0, 0, G.Width, G.Height);
  FBmp.Canvas.Draw(0, 0, G);
  FHasImage := True;
  FGlyphs := nil;
  FMode := gmNone;
  UpdateBinary;
  UpdateImageSize;
  AlignTokens;
  Caption := 'Lazarus OCR - ' + Source;
  Log(Format('Image loaded: %s (%d x %d)', [Source, G.Width, G.Height]));
end;

procedure TFormMain.UpdateBinary;
var
  Img: TLazIntfImage;
  x, y: Integer;
begin
  tbThreshold.Enabled := not chkAutoThreshold.Checked;
  if not FHasImage then Exit;
  FBin := BitmapToBinary(FBmp, GetOptions, FThreshold);
  FUpdating := True;
  try
    tbThreshold.Position := FThreshold;
  finally
    FUpdating := False;
  end;
  lblThreshold.Caption := Format('Threshold: %d', [FThreshold]);

  if chkShowBinary.Checked then
  begin
    FBinBmp.PixelFormat := pf24bit;
    FBinBmp.SetSize(FBin.W, FBin.H);
    Img := FBinBmp.CreateIntfImage;
    try
      for y := 0 to FBin.H - 1 do
        for x := 0 to FBin.W - 1 do
          if FBin.Data[y * FBin.W + x] = 1 then
            Img.Colors[x, y] := colBlack
          else
            Img.Colors[x, y] := colWhite;
      FBinBmp.LoadFromIntfImage(Img);
    finally
      Img.Free;
    end;
  end;
end;

procedure TFormMain.UpdateImageSize;
begin
  if FHasImage then
    pbImage.SetBounds(0, 0, Round(FBmp.Width * FZoom), Round(FBmp.Height * FZoom))
  else
    pbImage.SetBounds(0, 0, 10, 10);
  pbImage.Invalidate;
end;

procedure TFormMain.cbZoomChange(Sender: TObject);
begin
  FZoom := ZOOMS[EnsureRange(cbZoom.ItemIndex, 0, High(ZOOMS))];
  UpdateImageSize;
end;

procedure TFormMain.btnOpenClick(Sender: TObject);
begin
  if OpenPictureDialog1.Execute then
    LoadImageFile(OpenPictureDialog1.FileName);
end;

procedure TFormMain.btnPasteClick(Sender: TObject);
var
  Pic: TPicture;
begin
  if not Clipboard.HasPictureFormat then
  begin
    MessageDlg('The clipboard does not contain an image.', mtInformation, [mbOK], 0);
    Exit;
  end;
  Pic := TPicture.Create;
  try
    Pic.LoadFromClipboardFormat(Clipboard.FindPictureFormatID);
    SetImageFromGraphic(Pic.Graphic, 'clipboard');
  finally
    Pic.Free;
  end;
end;

procedure TFormMain.btnSaveImageClick(Sender: TObject);
var
  Png: TPortableNetworkGraphic;
begin
  if not FHasImage then Exit;
  if not SaveImageDialog.Execute then Exit;
  if LowerCase(ExtractFileExt(SaveImageDialog.FileName)) = '.bmp' then
    FBmp.SaveToFile(SaveImageDialog.FileName)
  else
  begin
    Png := TPortableNetworkGraphic.Create;
    try
      Png.Assign(FBmp);
      Png.SaveToFile(SaveImageDialog.FileName);
    finally
      Png.Free;
    end;
  end;
  Log('Image saved: ' + SaveImageDialog.FileName);
end;

procedure TFormMain.btnFontSampleClick(Sender: TObject);
const
  MARGIN = 24;
var
  Lines: TStringList;
  Toks: array of TStringArr;
  Bmp: TBitmap;
  i, j, x, y, W, LW, Gap, LineH, TH: Integer;
begin
  if Trim(memoLabels.Text) = '' then
    memoLabels.Text := DEFAULT_TEXT;
  if not FontDialog1.Execute then Exit;

  Lines := TStringList.Create;
  Bmp := TBitmap.Create;
  try
    Lines.Text := memoLabels.Text;
    SetLength(Toks, Lines.Count);
    for i := 0 to Lines.Count - 1 do
      if chkWholeImage.Checked then
      begin
        // whole-image mode: draw each line as normal text
        if Trim(Lines[i]) <> '' then
        begin
          SetLength(Toks[i], 1);
          Toks[i][0] := Trim(Lines[i]);
        end;
      end
      else
        Toks[i] := TokenizeLabels(Lines[i], chkSplitSpace.Checked, chkMergeParts.Checked);

    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(16, 16);
    Bmp.Canvas.Font.Assign(FontDialog1.Font);
    TH := Bmp.Canvas.TextHeight('Ag');
    Gap := Max(3, TH div 4);
    LineH := Round(TH * 1.6);

    // measure the image size
    W := 0;
    for i := 0 to High(Toks) do
    begin
      LW := 0;
      for j := 0 to High(Toks[i]) do
        Inc(LW, Bmp.Canvas.TextWidth(Toks[i][j]) + Gap);
      W := Max(W, LW);
    end;
    Bmp.SetSize(W + 2 * MARGIN, Lines.Count * LineH + 2 * MARGIN);
    Bmp.Canvas.Brush.Style := bsSolid;
    Bmp.Canvas.Brush.Color := clWhite;
    Bmp.Canvas.FillRect(0, 0, Bmp.Width, Bmp.Height);
    Bmp.Canvas.Font.Assign(FontDialog1.Font);
    Bmp.Canvas.Font.Color := clBlack;
    Bmp.Canvas.Brush.Style := bsClear;

    // draw one symbol at a time with a gap so they are easy to segment
    y := MARGIN;
    for i := 0 to High(Toks) do
    begin
      x := MARGIN;
      for j := 0 to High(Toks[i]) do
      begin
        Bmp.Canvas.TextOut(x, y, Toks[i][j]);
        Inc(x, Bmp.Canvas.TextWidth(Toks[i][j]) + Gap);
      end;
      Inc(y, LineH);
    end;

    SetImageFromGraphic(Bmp, Format('font %s %dpt', [FontDialog1.Font.Name, FontDialog1.Font.Size]));
  finally
    Bmp.Free;
    Lines.Free;
  end;
  pcMain.ActivePage := tsLearn;
  btnSegmentClick(nil);
end;

{ ---------- Segmentation / learning ---------- }

procedure TFormMain.DoSegment(Quiet, Whole: Boolean);
var
  Opt: TOcrOptions;
begin
  if not FHasImage then Exit;
  UpdateBinary;
  Opt := GetOptions;
  Opt.WholeImage := Whole;
  FGlyphs := SegmentGlyphs(FBin, Opt);
  if not Quiet then
    Log(Format('Found %d symbol(s) (threshold %d)', [Length(FGlyphs), FThreshold]));
end;

procedure TFormMain.AlignTokens;
var
  i, NG: Integer;
begin
  FTokens := GetTokens;
  if FMode = gmLearn then
  begin
    for i := 0 to High(FGlyphs) do
      if i < Length(FTokens) then
        FGlyphs[i].Text := FTokens[i]
      else
        FGlyphs[i].Text := '';
    NG := Length(FGlyphs);
    lblMatch.Caption := Format('Symbols in image: %d    Labels: %d', [NG, Length(FTokens)]);
    if (NG > 0) and (NG = Length(FTokens)) then
      lblMatch.Font.Color := clGreen
    else
      lblMatch.Font.Color := clRed;
  end
  else
  begin
    lblMatch.Caption := Format('Labels: %d  (click "Segment symbols" to match them)', [Length(FTokens)]);
    lblMatch.Font.Color := clWindowText;
  end;
  UpdateGlyphPanel;
  pbImage.Invalidate;
end;

procedure TFormMain.memoLabelsChange(Sender: TObject);
begin
  if FUpdating then Exit;
  AlignTokens;
end;

procedure TFormMain.btnSegmentClick(Sender: TObject);
begin
  if not FHasImage then
  begin
    MessageDlg('Please open an image first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  DoSegment(False, chkWholeImage.Checked);
  FMode := gmLearn;
  AlignTokens;
end;

procedure TFormMain.btnAddSamplesClick(Sender: TObject);
var
  i: Integer;
begin
  if not FHasImage then
  begin
    MessageDlg('Please open an image first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if FMode <> gmLearn then
  begin
    DoSegment(False, chkWholeImage.Checked);
    FMode := gmLearn;
  end;
  AlignTokens;
  if Length(FGlyphs) = 0 then
  begin
    MessageDlg('No symbols were found in the image.', mtWarning, [mbOK], 0);
    Exit;
  end;
  if Length(FTokens) <> Length(FGlyphs) then
  begin
    MessageDlg(Format('The number of labels (%d) does not match the number of symbols found (%d).' + LineEnding +
      'Check the text, or adjust the Settings tab (see the symbol strip below the image).',
      [Length(FTokens), Length(FGlyphs)]), mtWarning, [mbOK], 0);
    Exit;
  end;
  for i := 0 to High(FGlyphs) do
    FModel.AddSample(FTokens[i], FGlyphs[i].Feat);
  RefreshClassList;
  Log(Format('Added %d sample(s) (total %d samples, %d classes). k-NN / centroid work now; ' +
    'click "Start training" for the neural network.', [Length(FGlyphs), FModel.SampleCount, FModel.ClassCount]));
end;

procedure TFormMain.btnBatchLearnClick(Sender: TObject);
var
  Tokens: TStringArr;
  Opt: TOcrOptions;
  Tmp: TBitmap;
  Bin: TBinImage;
  G: TGlyphArray;
  i, j, Th, Added, Skipped, Samples: Integer;
  LastOK, LabelText: string;
begin
  Tokens := GetTokens;
  if Length(Tokens) = 0 then
  begin
    MessageDlg('Type the label shared by all images first (e.g. "A" or "STOP").', mtInformation, [mbOK], 0);
    memoLabels.SetFocus;
    Exit;
  end;
  if not OpenBatchDialog.Execute then Exit;

  LabelText := '';
  for i := 0 to High(Tokens) do
  begin
    if i > 0 then LabelText := LabelText + ' ';
    LabelText := LabelText + Tokens[i];
  end;
  Opt := GetOptions;
  Opt.WholeImage := chkWholeImage.Checked;
  Added := 0;
  Skipped := 0;
  Samples := 0;
  LastOK := '';
  FBusy := True;
  FStopRequested := False;
  UpdateButtons;
  Tmp := TBitmap.Create;
  try
    Log(Format('Batch learning %d image(s) with label "%s"...', [OpenBatchDialog.Files.Count, LabelText]));
    for i := 0 to OpenBatchDialog.Files.Count - 1 do
    begin
      if FStopRequested then Break;
      StatusBar1.SimpleText := Format('Learning %d / %d: %s',
        [i + 1, OpenBatchDialog.Files.Count, ExtractFileName(OpenBatchDialog.Files[i])]);
      Application.ProcessMessages;
      if not LoadBitmap(OpenBatchDialog.Files[i], Tmp) then
      begin
        Inc(Skipped);
        Continue;
      end;
      Bin := BitmapToBinary(Tmp, Opt, Th);
      G := SegmentGlyphs(Bin, Opt);
      if Length(G) <> Length(Tokens) then
      begin
        Log(Format('  skipped %s: found %d symbol(s), expected %d',
          [ExtractFileName(OpenBatchDialog.Files[i]), Length(G), Length(Tokens)]));
        Inc(Skipped);
        Continue;
      end;
      for j := 0 to High(G) do
        FModel.AddSample(Tokens[j], G[j].Feat);
      Inc(Samples, Length(G));
      Inc(Added);
      LastOK := OpenBatchDialog.Files[i];
    end;
  finally
    Tmp.Free;
    FBusy := False;
    UpdateButtons;
  end;

  RefreshClassList;
  Log(Format('Batch learning done: %d image(s) added (%d samples), %d skipped. Total: %d samples, %d classes.',
    [Added, Samples, Skipped, FModel.SampleCount, FModel.ClassCount]));
  // show the last image that was learned, with its labels
  if LastOK <> '' then
  begin
    LoadImageFile(LastOK);
    btnSegmentClick(nil);
  end;
  if Skipped > 0 then
    MessageDlg(Format('%d image(s) added, %d skipped (see the log for details).' + LineEnding +
      'Tip: tick "Whole image is ONE symbol" if the images cannot be split into the expected characters.',
      [Added, Skipped]), mtInformation, [mbOK], 0);
end;

procedure TFormMain.btnDeleteClassClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := lbClasses.ItemIndex;
  if Idx < 0 then Exit;
  if MessageDlg(Format('Delete class "%s" and all of its samples?', [FModel.Classes[Idx]]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  Log('Deleted class: ' + FModel.Classes[Idx]);
  FModel.DeleteClass(Idx);
  RefreshClassList;
end;

function TFormMain.TrainProgress(Epoch, Total: Integer; Loss, Acc: Single): Boolean;
begin
  pbTrain.Position := Epoch * 100 div Total;
  lblTrain.Caption := Format('Epoch %d/%d   loss %.4f   accuracy %.1f%%', [Epoch, Total, Loss, Acc * 100]);
  Application.ProcessMessages;
  Result := not FStopRequested;
end;

procedure TFormMain.btnTrainClick(Sender: TObject);
var
  Acc: Single;
  T0: QWord;
begin
  if FModel.ClassCount < 2 then
  begin
    MessageDlg('At least 2 classes are needed before training.', mtInformation, [mbOK], 0);
    Exit;
  end;
  FTraining := True;
  FStopRequested := False;
  UpdateButtons;
  T0 := GetTickCount64;
  Log(Format('Training: %d samples, %d classes, %d hidden neurons, %d epochs',
    [FModel.SampleCount, FModel.ClassCount, seHidden.Value, seEpochs.Value]));
  try
    Acc := FModel.Train(seEpochs.Value, seHidden.Value, seLR.Value, chkAugment.Checked, @TrainProgress);
  finally
    FTraining := False;
    UpdateButtons;
  end;
  pbTrain.Position := 100;
  lblTrain.Caption := Format('Done: training accuracy %.1f%%  (%.1f s)',
    [Acc * 100, (GetTickCount64 - T0) / 1000]);
  Log(lblTrain.Caption);
  RefreshClassList;
end;

procedure TFormMain.btnStopClick(Sender: TObject);
begin
  FStopRequested := True;
end;

{ ---------- Reading ---------- }

procedure TFormMain.btnRecognizeClick(Sender: TObject);
var
  Opt: TOcrOptions;
  M: TClassifier;
  Avg: Single;
  S: string;
begin
  if not FHasImage then
  begin
    MessageDlg('Please open an image first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if FModel.SampleCount = 0 then
  begin
    MessageDlg('Nothing has been learned yet. Teach some symbols on the Learn tab first.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  DoSegment(False, chkReadWhole.Checked);
  Opt := GetOptions;

  if cbMethod.ItemIndex = COMPARE_ALL then
  begin
    S := '';
    for M := Low(TClassifier) to High(TClassifier) do
    begin
      if (M = clsMLP) and not FModel.NetReady then
      begin
        S := S + '[' + CLASSIFIER_NAMES[M] + ']  not trained' + LineEnding + LineEnding;
        Continue;
      end;
      Avg := ClassifyGlyphs(FGlyphs, M);
      S := S + Format('[%s]  avg. confidence %.0f%%', [CLASSIFIER_NAMES[M], Avg * 100]) + LineEnding +
        GlyphsToText(FGlyphs, Opt) + LineEnding + LineEnding;
    end;
    // the boxes on the image show the ensemble result (classified last)
    memoResult.Text := TrimRight(S);
    Log(Format('Compared all classifiers on %d symbol(s)', [Length(FGlyphs)]));
  end
  else
  begin
    M := SelectedMethod;
    if (M = clsMLP) and not FModel.NetReady then
      Log('The neural network is not trained (or new classes were added) - using k-NN instead.');
    Avg := ClassifyGlyphs(FGlyphs, M);
    memoResult.Text := GlyphsToText(FGlyphs, Opt);
    if Length(FGlyphs) > 0 then
      Log(Format('Read %d symbol(s) with %s, avg. confidence %.1f%%',
        [Length(FGlyphs), CLASSIFIER_NAMES[M], Avg * 100]));
  end;
  FMode := gmRead;
  AlignTokens;
end;

procedure TFormMain.btnBatchReadClick(Sender: TObject);
var
  Opt: TOcrOptions;
  M: TClassifier;
  Tmp: TBitmap;
  Bin: TBinImage;
  G: TGlyphArray;
  Lines: TStringList;
  i, Th: Integer;
  Avg: Single;
  LastOK, Txt: string;
begin
  if FModel.SampleCount = 0 then
  begin
    MessageDlg('Nothing has been learned yet. Teach some symbols on the Learn tab first.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  if not OpenBatchDialog.Execute then Exit;
  M := SelectedMethod;   // "Compare all" uses the ensemble vote for batches
  Opt := GetOptions;
  Opt.WholeImage := chkReadWhole.Checked;
  LastOK := '';
  FBusy := True;
  FStopRequested := False;
  UpdateButtons;
  Tmp := TBitmap.Create;
  Lines := TStringList.Create;
  try
    for i := 0 to OpenBatchDialog.Files.Count - 1 do
    begin
      if FStopRequested then Break;
      StatusBar1.SimpleText := Format('Reading %d / %d', [i + 1, OpenBatchDialog.Files.Count]);
      Application.ProcessMessages;
      if not LoadBitmap(OpenBatchDialog.Files[i], Tmp) then
      begin
        Lines.Add(ExtractFileName(OpenBatchDialog.Files[i]) + ':  (cannot open)');
        Continue;
      end;
      Bin := BitmapToBinary(Tmp, Opt, Th);
      G := SegmentGlyphs(Bin, Opt);
      Avg := ClassifyGlyphs(G, M);
      Txt := StringReplace(GlyphsToText(G, Opt), LineEnding, ' / ', [rfReplaceAll]);
      Lines.Add(Format('%s:  %s   (%.0f%%)', [ExtractFileName(OpenBatchDialog.Files[i]), Txt, Avg * 100]));
      LastOK := OpenBatchDialog.Files[i];
    end;
    memoResult.Text := Lines.Text;
  finally
    Lines.Free;
    Tmp.Free;
    FBusy := False;
    UpdateButtons;
    RefreshClassList;
  end;
  Log(Format('Read %d image(s) with %s', [OpenBatchDialog.Files.Count, CLASSIFIER_NAMES[M]]));
  // show the last image with its boxes
  if LastOK <> '' then
  begin
    LoadImageFile(LastOK);
    DoSegment(True, chkReadWhole.Checked);
    ClassifyGlyphs(FGlyphs, M);
    FMode := gmRead;
    AlignTokens;
  end;
end;

procedure TFormMain.btnCopyResultClick(Sender: TObject);
begin
  Clipboard.AsText := memoResult.Text;
end;

procedure TFormMain.btnUseResultClick(Sender: TObject);
var
  S: string;
  i: Integer;
begin
  if (FMode <> gmRead) or (Length(FGlyphs) = 0) then
  begin
    MessageDlg('Click "Read text from image" first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  S := '';
  for i := 0 to High(FGlyphs) do
  begin
    if i > 0 then
      if FGlyphs[i].Line <> FGlyphs[i - 1].Line then
        S := S + LineEnding
      else
        S := S + ' ';
    S := S + FGlyphs[i].Text;
  end;
  FMode := gmLearn;
  FUpdating := True;
  try
    chkWholeImage.Checked := chkReadWhole.Checked;
    chkSplitSpace.Checked := not chkReadWhole.Checked;
    memoLabels.Text := S;
  finally
    FUpdating := False;
  end;
  pcMain.ActivePage := tsLearn;
  AlignTokens;
  Log('Correct the wrong labels (one label per symbol, separated by spaces), then click "Add as training samples".');
end;

{ ---------- Settings ---------- }

procedure TFormMain.SettingsChange(Sender: TObject);
begin
  if FUpdating then Exit;
  UpdateBinary;
  if not FHasImage then
  begin
    AlignTokens;
    Exit;
  end;
  if FMode = gmLearn then
    DoSegment(True, chkWholeImage.Checked)
  else if FMode = gmRead then
  begin
    FGlyphs := nil;
    FMode := gmNone;
  end;
  AlignTokens;
end;

procedure TFormMain.chkShowBoxesChange(Sender: TObject);
begin
  pbImage.Invalidate;
end;

{ ---------- Model ---------- }

procedure TFormMain.btnSaveModelClick(Sender: TObject);
begin
  if not SaveDialog1.Execute then Exit;
  FModel.SaveToFile(SaveDialog1.FileName);
  Log('Model saved: ' + SaveDialog1.FileName);
end;

procedure TFormMain.btnLoadModelClick(Sender: TObject);
begin
  if not OpenDialog1.Execute then Exit;
  try
    FModel.LoadFromFile(OpenDialog1.FileName);
    Log(Format('Model loaded: %s (%d samples)', [OpenDialog1.FileName, FModel.SampleCount]));
  except
    on E: Exception do
      MessageDlg('Cannot load the model: ' + E.Message, mtError, [mbOK], 0);
  end;
  RefreshClassList;
end;

procedure TFormMain.btnClearModelClick(Sender: TObject);
begin
  if MessageDlg('Delete everything that has been learned?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FModel.Clear;
  if FileExists(FModelFile) then
    DeleteFile(FModelFile);
  RefreshClassList;
  lblTrain.Caption := 'Not trained';
  pbTrain.Position := 0;
  Log('Model cleared');
end;

{ ---------- Drawing ---------- }

procedure TFormMain.pbImagePaint(Sender: TObject);
var
  C: TCanvas;
  Src: TBitmap;
  R: TRect;
  i, TH: Integer;
  S: string;
begin
  C := pbImage.Canvas;
  if not FHasImage then
  begin
    C.Brush.Color := clGray;
    C.FillRect(pbImage.ClientRect);
    Exit;
  end;
  if chkShowBinary.Checked and (FBinBmp.Width = FBmp.Width) and (FBinBmp.Height = FBmp.Height) then
    Src := FBinBmp
  else
    Src := FBmp;
  C.StretchDraw(Rect(0, 0, Round(Src.Width * FZoom), Round(Src.Height * FZoom)), Src);

  if not chkShowBoxes.Checked then Exit;
  C.Font.Size := 9;
  C.Font.Style := [fsBold];
  C.Font.Color := clBlack;
  TH := C.TextHeight('Ag');
  for i := 0 to High(FGlyphs) do
  begin
    R := Rect(Round(FGlyphs[i].R.Left * FZoom) - 1, Round(FGlyphs[i].R.Top * FZoom) - 1,
      Round(FGlyphs[i].R.Right * FZoom) + 1, Round(FGlyphs[i].R.Bottom * FZoom) + 1);
    case FMode of
      gmLearn:
        if FGlyphs[i].Text = '' then C.Pen.Color := clRed else C.Pen.Color := $00A000;
      gmRead:
        if FGlyphs[i].Conf < 0.5 then C.Pen.Color := $0080FF else C.Pen.Color := clBlue;
    else
      C.Pen.Color := clGray;
    end;
    C.Brush.Style := bsClear;
    C.Rectangle(R);
    S := FGlyphs[i].Text;
    if S <> '' then
    begin
      C.Brush.Style := bsSolid;
      C.Brush.Color := clYellow;
      C.TextOut(R.Left, Max(0, R.Top - TH - 1), S);
    end;
  end;
  C.Brush.Style := bsSolid;
end;

procedure TFormMain.UpdateGlyphPanel;
var
  Cols, Rows: Integer;
begin
  Cols := Max(1, sbGlyphs.ClientWidth div CELL_W);
  Rows := (Length(FGlyphs) + Cols - 1) div Cols;
  pbGlyphs.Height := Max(sbGlyphs.ClientHeight - 4, Rows * CELL_H + 4);
  pbGlyphs.Invalidate;
end;

procedure TFormMain.sbGlyphsResize(Sender: TObject);
begin
  UpdateGlyphPanel;
end;

procedure TFormMain.pbGlyphsPaint(Sender: TObject);
var
  C: TCanvas;
  Cols, i, gx, gy, X0, Y0, BX, BY, V, TW: Integer;
  S: string;
begin
  C := pbGlyphs.Canvas;
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWhite;
  C.FillRect(pbGlyphs.ClientRect);
  Cols := Max(1, pbGlyphs.Width div CELL_W);
  for i := 0 to High(FGlyphs) do
  begin
    X0 := (i mod Cols) * CELL_W + 2;
    Y0 := (i div Cols) * CELL_H + 2;
    C.Brush.Style := bsClear;
    C.Font.Size := 7;
    C.Font.Style := [];
    C.Font.Color := clGray;
    C.TextOut(X0 + 2, Y0, IntToStr(i + 1));

    // the GRID x GRID image of the symbol (exactly what the classifier sees)
    BX := X0 + (CELL_W - GRID * CELL_PIX) div 2;
    BY := Y0 + 12;
    C.Brush.Style := bsSolid;
    for gy := 0 to GRID - 1 do
      for gx := 0 to GRID - 1 do
      begin
        V := 255 - Round(FGlyphs[i].Feat[gy * GRID + gx] * 255);
        C.Brush.Color := RGBToColor(V, V, V);
        C.FillRect(BX + gx * CELL_PIX, BY + gy * CELL_PIX,
          BX + (gx + 1) * CELL_PIX, BY + (gy + 1) * CELL_PIX);
      end;
    C.Brush.Style := bsClear;
    C.Pen.Color := clSilver;
    C.Rectangle(BX - 1, BY - 1, BX + GRID * CELL_PIX + 1, BY + GRID * CELL_PIX + 1);

    S := FGlyphs[i].Text;
    C.Font.Size := 11;
    C.Font.Style := [fsBold];
    if S = '' then
    begin
      S := '?';
      C.Font.Color := clRed;
    end
    else if (FMode = gmRead) and (FGlyphs[i].Conf < 0.5) then
      C.Font.Color := $0060C0
    else
      C.Font.Color := clNavy;
    TW := C.TextWidth(S);
    C.TextOut(X0 + (CELL_W - TW) div 2, BY + GRID * CELL_PIX + 2, S);
  end;
  C.Brush.Style := bsSolid;
end;

end.

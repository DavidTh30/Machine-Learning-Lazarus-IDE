program LazOCR;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, mainform, OcrEngine, OcrModel, ModelInspector;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Lazarus OCR';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TFormMain, FormMain);
  Application.Run;
end.

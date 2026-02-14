object Form1: TForm1
  Left = 0
  Top = 0
  Margins.Left = 5
  Margins.Top = 5
  Margins.Right = 5
  Margins.Bottom = 5
  Caption = 'TypeWriter'
  ClientHeight = 995
  ClientWidth = 1335
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -18
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnKeyDown = FormKeyDown
  PixelsPerInch = 144
  DesignSize = (
    1335
    995)
  TextHeight = 25
  object SynEdit1: TSynEdit
    AlignWithMargins = True
    Left = 0
    Top = 70
    Width = 1335
    Height = 855
    Margins.Left = 0
    Margins.Top = 70
    Margins.Right = 0
    Margins.Bottom = 70
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -20
    Font.Name = 'Consolas'
    Font.Style = []
    Font.Quality = fqClearTypeNatural
    TabOrder = 0
    UseCodeFolding = False
    BookMarkOptions.LeftMargin = 3
    BookMarkOptions.Xoffset = 18
    ExtraLineSpacing = 3
    Gutter.Font.Charset = DEFAULT_CHARSET
    Gutter.Font.Color = clWindowText
    Gutter.Font.Height = -24
    Gutter.Font.Name = 'Consolas'
    Gutter.Font.Style = []
    Gutter.Font.Quality = fqClearTypeNatural
    Gutter.Bands = <
      item
        Kind = gbkMarks
        Width = 13
      end
      item
        Kind = gbkLineNumbers
      end
      item
        Kind = gbkFold
      end
      item
        Kind = gbkTrackChanges
      end
      item
        Kind = gbkMargin
        Width = 3
      end>
    SelectedColor.Alpha = 0.400000005960464500
    WantReturns = False
  end
  object bSendMemoText: TButton
    Left = 24
    Top = 936
    Width = 113
    Height = 38
    Margins.Left = 5
    Margins.Top = 5
    Margins.Right = 5
    Margins.Bottom = 5
    Anchors = [akLeft, akBottom]
    Caption = 'Send'
    TabOrder = 1
    OnClick = bSendMemoTextClick
  end
  object cbShowSpecial: TCheckBox
    Left = 1084
    Top = 942
    Width = 241
    Height = 26
    Margins.Left = 5
    Margins.Top = 5
    Margins.Right = 5
    Margins.Bottom = 5
    Anchors = [akRight, akBottom]
    Caption = 'Show Special Characters'
    Checked = True
    State = cbChecked
    TabOrder = 2
    OnClick = cbShowSpecialClick
  end
  object bClearText: TButton
    Left = 168
    Top = 936
    Width = 113
    Height = 38
    Margins.Left = 5
    Margins.Top = 5
    Margins.Right = 5
    Margins.Bottom = 5
    Anchors = [akLeft, akBottom]
    Caption = 'Clear'
    TabOrder = 3
    OnClick = bClearTextClick
  end
end

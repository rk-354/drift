<#
.SYNOPSIS
  Drift — screen-break and water reminders in the Windows system tray.

.DESCRIPTION
  Every 30 minutes (by default) a small card asks you to look away from the
  screen for 20 seconds; every 60 minutes another asks you to drink a glass of
  water. Both intervals, the break length and the daily water target are
  adjustable from the tray icon's Settings.

  Built to stay out of the way:
    - While Windows reports you are presenting or running something full
      screen, reminders wait until you are done.
    - The cards never take focus, so they cannot swallow what you are typing.

  Uses only what ships with Windows (PowerShell 5.1 and WinForms): no install,
  no admin rights, no network.

.PARAMETER Demo
  Short intervals (break every 1 min, water every 2 min, 5-second break) for
  trying it out. Your saved settings are not changed.

.PARAMETER SelfTest
  Runs the scheduling logic checks and exits. Used by test.ps1.
#>
[CmdletBinding()]
param(
  [switch]$Demo,
  [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Native helpers ───────────────────────────────────────────────────────────
# C# 5 syntax only: PowerShell 5.1's Add-Type compiles with the .NET Framework
# compiler, which predates expression-bodied members.
if (-not ('Drift.Native' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Drift {
  public static class Native {
    [DllImport("shell32.dll")]
    static extern int SHQueryUserNotificationState(out int state);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);

    /// Crisp text on scaled (125 % / 150 %) displays instead of a blurry bitmap stretch.
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    /// True when Windows itself would hold back notifications: a full-screen
    /// app, a Direct3D game or video, or presentation mode.
    public static bool IsBusy() {
      int state;
      if (SHQueryUserNotificationState(out state) != 0) return false;
      // 2 = busy (full screen), 3 = running D3D full screen, 4 = presentation mode
      return state == 2 || state == 3 || state == 4;
    }
  }

  /// A window that shows on top without stealing focus from what you are doing.
  public class QuietForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
      get {
        CreateParams cp = base.CreateParams;
        cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
        cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
        cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW: no taskbar button
        cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
        return cp;
      }
    }
  }
}
'@
}

# The reminder card itself. Drawn entirely by hand in C# so it can have rounded
# corners, a soft shadow, gradient art, pill buttons, a smooth countdown ring
# and an entrance animation — none of which stock WinForms controls offer, and
# all of which would flicker if painted from PowerShell.
if (-not ('Drift.ReminderCard' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Drift {
  public class CardButtonEventArgs : EventArgs {
    public int Index;
    public CardButtonEventArgs(int index) { Index = index; }
  }

  public class ReminderCard : Form {
    public event EventHandler<CardButtonEventArgs> ButtonClicked;
    public event EventHandler Dismissed;
    public event EventHandler CountdownFinished;

    // Shows on top without stealing focus from what you are typing.
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
      get {
        CreateParams cp = base.CreateParams;
        cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
        cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
        cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW: no taskbar button
        cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
        return cp;
      }
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    readonly string kind, eyebrow, title;
    string body, footnote;
    readonly string[] buttons;
    readonly Color accent, accentDeep, accentSoft;
    readonly float s;
    readonly Font fEyebrow, fTitle, fBody, fButton, fCount, fSmall;

    RectangleF[] buttonRects = new RectangleF[0];
    RectangleF closeRect;
    int hoverButton = -1;
    bool hoverClose;

    int glasses, target;
    bool showGlasses;

    bool counting;
    double countTotal;
    DateTime countStart;
    Timer tick, intro, drift;
    double appear;
    readonly DateTime born = DateTime.Now;
    int restTop;

    public ReminderCard(string kind, string eyebrow, string title, string body, Color accent, Color accentDeep, string[] buttons) {
      this.kind = kind; this.eyebrow = eyebrow; this.title = title; this.body = body;
      this.accent = accent; this.accentDeep = accentDeep; this.buttons = buttons;
      this.accentSoft = Blend(accent, Color.White, 0.88);

      SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      FormBorderStyle = FormBorderStyle.None;
      StartPosition = FormStartPosition.Manual;
      ShowInTaskbar = false;
      TopMost = true;
      BackColor = Color.White;

      using (Graphics g = CreateGraphics()) { s = g.DpiX / 96f; }
      fEyebrow = MakeFont(new[] { "Segoe UI Variable Text", "Segoe UI" }, 7.5f, FontStyle.Bold);
      fTitle = MakeFont(new[] { "Segoe UI Variable Display Semib", "Segoe UI Semibold", "Segoe UI" }, 15f, FontStyle.Regular);
      fBody = MakeFont(new[] { "Segoe UI Variable Text", "Segoe UI" }, 10f, FontStyle.Regular);
      fButton = MakeFont(new[] { "Segoe UI Variable Text Semibold", "Segoe UI Semibold", "Segoe UI" }, 9.5f, FontStyle.Regular);
      fCount = MakeFont(new[] { "Segoe UI Variable Display Semib", "Segoe UI Semibold", "Segoe UI" }, 20f, FontStyle.Regular);
      fSmall = MakeFont(new[] { "Segoe UI Variable Text", "Segoe UI" }, 8.5f, FontStyle.Regular);

      Relayout(false);
      Opacity = 0;
    }

    static Font MakeFont(string[] families, float size, FontStyle style) {
      foreach (string fam in families) {
        Font f = new Font(fam, size, style);
        if (string.Equals(f.Name, fam, StringComparison.OrdinalIgnoreCase)) return f;
        f.Dispose();
      }
      return new Font("Segoe UI", size, style);
    }

    static Color Blend(Color a, Color b, double t) {
      return Color.FromArgb(
        (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }

    float S(float v) { return v * s; }

    void Relayout(bool keepBottom) {
      int bottom = Bottom;
      Size = new Size((int)S(424), (int)S(showGlasses ? 214 : 192));
      Rectangle wa = Screen.PrimaryScreen.WorkingArea;
      Left = wa.Right - Width - (int)S(20);
      Top = keepBottom ? bottom - Height : wa.Bottom - Height - (int)S(20);
      restTop = Top;
      ApplyShape();
      Invalidate();
    }

    void ApplyShape() {
      // Windows 11 rounds the window itself (and keeps the shadow); older
      // Windows gets a rounded region.
      if (!IsHandleCreated) return;
      int pref = 2; // DWMWCP_ROUND
      bool dwm = false;
      try { dwm = DwmSetWindowAttribute(Handle, 33, ref pref, 4) == 0 && Environment.OSVersion.Version.Build >= 22000; } catch { }
      if (!dwm) {
        using (GraphicsPath p = Rounded(new RectangleF(0, 0, Width, Height), S(14))) { Region = new Region(p); }
      }
    }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ApplyShape(); }

    public void SetGlasses(int drunk, int goal) {
      glasses = drunk; target = Math.Max(1, goal); showGlasses = true;
      Relayout(false);
    }

    public void SetBody(string text) { body = text; Invalidate(); }

    /// Replaces the buttons with a draining ring for `seconds`.
    public void StartCountdown(int seconds) {
      counting = true;
      countTotal = Math.Max(1, seconds);
      countStart = DateTime.Now;
      footnote = "Eyes off the screen. This closes by itself.";
      hoverButton = -1;
      Cursor = Cursors.Default;
      tick = new Timer();
      tick.Interval = 40;
      tick.Tick += delegate {
        double elapsed = (DateTime.Now - countStart).TotalSeconds;
        Invalidate();
        if (elapsed >= countTotal) {
          tick.Stop();
          if (CountdownFinished != null) CountdownFinished(this, EventArgs.Empty);
        }
      };
      tick.Start();
      Invalidate();
    }

    protected override void OnShown(EventArgs e) {
      base.OnShown(e);
      restTop = Top;
      Top = restTop + (int)S(16);
      appear = 0;
      intro = new Timer();
      intro.Interval = 15;
      intro.Tick += delegate {
        appear = Math.Min(1, appear + 0.07);
        double eased = 1 - Math.Pow(1 - appear, 3);
        Opacity = eased;
        Top = restTop + (int)(S(16) * (1 - eased));
        if (appear >= 1) { intro.Stop(); Opacity = 1; }
      };
      intro.Start();
      // The clouds drift, slowly enough to be felt rather than watched.
      drift = new Timer();
      drift.Interval = 60;
      drift.Tick += delegate { Invalidate(); };
      drift.Start();
    }

    protected override void Dispose(bool disposing) {
      if (disposing) {
        if (tick != null) tick.Dispose();
        if (intro != null) intro.Dispose();
        if (drift != null) drift.Dispose();
        fEyebrow.Dispose(); fTitle.Dispose(); fBody.Dispose(); fButton.Dispose(); fCount.Dispose(); fSmall.Dispose();
      }
      base.Dispose(disposing);
    }

    static GraphicsPath Rounded(RectangleF r, float radius) {
      GraphicsPath p = new GraphicsPath();
      float d = radius * 2;
      p.AddArc(r.X, r.Y, d, d, 180, 90);
      p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
      p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure();
      return p;
    }

    static GraphicsPath Drop(float cx, float top, float w, float h) {
      // A water drop: a point at the top, a round belly at the bottom.
      GraphicsPath p = new GraphicsPath();
      float r = w / 2;
      float belly = top + h - r;
      p.AddBezier(cx, top, cx, top, cx - r, belly - r * 0.7f, cx - r, belly);
      p.AddArc(cx - r, belly - r, w, w, 180, -180);
      p.AddBezier(cx + r, belly, cx + r, belly - r * 0.7f, cx, top, cx, top);
      p.CloseFigure();
      return p;
    }

    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      float W = Width, H = Height;

      DrawSky(g, W, H);
      // A faint outline so the card holds its edge on white backgrounds.
      using (GraphicsPath edge = Rounded(new RectangleF(0.5f, 0.5f, W - 1, H - 1), S(14)))
      using (Pen p = new Pen(Color.FromArgb(28, 20, 30, 60), 1)) { g.DrawPath(p, edge); }

      // Hero circle.
      float cx = S(58), cy = S(64), R = S(32);
      RectangleF hero = new RectangleF(cx - R, cy - R, R * 2, R * 2);
      if (!counting) {
        using (SolidBrush halo = new SolidBrush(Color.FromArgb(70, 255, 255, 255))) {
          g.FillEllipse(halo, hero.X - S(6), hero.Y - S(6), hero.Width + S(12), hero.Height + S(12));
        }
        using (LinearGradientBrush b = new LinearGradientBrush(hero, accent, accentDeep, 45f)) { g.FillEllipse(b, hero); }
        if (kind == "water") DrawDropArt(g, cx, cy);
        else if (kind == "morning") DrawSunArt(g, cx, cy);
        else if (kind == "afternoon") DrawRiseArt(g, cx, cy);
        else DrawEyeArt(g, cx, cy);
      } else {
        DrawRing(g, cx, cy, R + S(6));
      }

      // Text.
      float tx = S(110), tw = W - tx - S(44);
      using (SolidBrush eb = new SolidBrush(accentDeep)) {
        g.DrawString(Spaced(eyebrow), fEyebrow, eb, tx, S(20));
      }
      using (SolidBrush tb = new SolidBrush(Color.FromArgb(17, 24, 39))) {
        g.DrawString(title, fTitle, tb, new RectangleF(tx - S(2), S(34), tw + S(30), S(32)));
      }
      using (SolidBrush bb = new SolidBrush(Color.FromArgb(75, 85, 99))) {
        g.DrawString(body, fBody, bb, new RectangleF(tx, S(66), W - tx - S(22), S(44)));
      }

      if (showGlasses) DrawGlasses(g, tx, S(116));

      // Close.
      closeRect = new RectangleF(W - S(38), S(12), S(26), S(26));
      if (hoverClose) using (SolidBrush hb = new SolidBrush(Color.FromArgb(18, 0, 0, 0))) { g.FillEllipse(hb, closeRect); }
      using (Pen xp = new Pen(Color.FromArgb(120, 128, 140), S(1.6f))) {
        xp.StartCap = xp.EndCap = LineCap.Round;
        float m = S(9);
        g.DrawLine(xp, closeRect.X + m, closeRect.Y + m, closeRect.Right - m, closeRect.Bottom - m);
        g.DrawLine(xp, closeRect.Right - m, closeRect.Y + m, closeRect.X + m, closeRect.Bottom - m);
      }

      // Buttons, or the countdown footnote.
      float by = H - S(52);
      if (counting) {
        buttonRects = new RectangleF[0];
        using (SolidBrush fb = new SolidBrush(Color.FromArgb(107, 114, 128))) { g.DrawString(footnote, fSmall, fb, tx, by + S(10)); }
        double frac = Math.Min(1, (DateTime.Now - countStart).TotalSeconds / countTotal);
        RectangleF track = new RectangleF(tx, by + S(32), W - tx - S(22), S(4));
        using (GraphicsPath tp = Rounded(track, S(2))) using (SolidBrush tb2 = new SolidBrush(accentSoft)) { g.FillPath(tb2, tp); }
        if (frac > 0.01) {
          RectangleF fill = new RectangleF(track.X, track.Y, (float)(track.Width * frac), track.Height);
          using (GraphicsPath fp = Rounded(fill, S(2))) using (SolidBrush fbb = new SolidBrush(accent)) { g.FillPath(fbb, fp); }
        }
        return;
      }
      buttonRects = new RectangleF[buttons.Length];
      float x = tx;
      for (int i = 0; i < buttons.Length; i++) {
        SizeF ts = g.MeasureString(buttons[i], fButton);
        float bw = ts.Width + S(i == 0 ? 30 : 24);
        RectangleF r = new RectangleF(x, by, bw, S(34));
        buttonRects[i] = r;
        bool hot = hoverButton == i;
        using (GraphicsPath bp = Rounded(r, S(17))) {
          if (i == 0) {
            Color c1 = hot ? Blend(accent, Color.White, 0.12) : accent;
            using (LinearGradientBrush pb = new LinearGradientBrush(r, c1, accentDeep, 90f)) { g.FillPath(pb, bp); }
            DrawCentered(g, buttons[i], fButton, Color.White, r);
          } else {
            using (SolidBrush pb = new SolidBrush(hot ? Color.FromArgb(240, 242, 247) : Color.FromArgb(220, 255, 255, 255))) { g.FillPath(pb, bp); }
            using (Pen op = new Pen(Color.FromArgb(hot ? 70 : 45, 30, 40, 70), 1)) { g.DrawPath(op, bp); }
            DrawCentered(g, buttons[i], fButton, Color.FromArgb(31, 41, 55), r);
          }
        }
        x += bw + S(8);
      }
    }

    static string Spaced(string t) {
      string u = t.ToUpperInvariant();
      System.Text.StringBuilder sb = new System.Text.StringBuilder();
      for (int i = 0; i < u.Length; i++) { if (i > 0) sb.Append('\u200A'); sb.Append(u[i]); }
      return sb.ToString();
    }

    // ── The sky ──────────────────────────────────────────────────────────
    // A pastel gradient, two translucent waves along the bottom, and a few
    // puffy clouds drifting a few pixels back and forth.

    void DrawSky(Graphics g, float W, float H) {
      Color top = Blend(accent, Color.White, 0.72);
      Color mid = Blend(Color.FromArgb(186, 220, 255), Color.White, 0.45);
      using (LinearGradientBrush sky = new LinearGradientBrush(new RectangleF(0, 0, W, H), top, Color.White, 90f)) {
        ColorBlend cb = new ColorBlend(3);
        cb.Colors = new Color[] { top, mid, Color.FromArgb(252, 253, 255) };
        cb.Positions = new float[] { 0f, 0.55f, 1f };
        sky.InterpolationColors = cb;
        g.FillRectangle(sky, 0, 0, W, H);
      }

      double t = (DateTime.Now - born).TotalSeconds;
      float dx = (float)(Math.Sin(t * 0.35) * S(7));
      float dy = (float)(Math.Sin(t * 0.5) * S(1.5f));

      // Soft glows: a warm or fresh tint drifting under the clouds.
      Color glow = kind == "water" ? Color.FromArgb(167, 243, 208)
        : kind == "morning" ? Color.FromArgb(254, 240, 138)
        : kind == "afternoon" ? Color.FromArgb(153, 246, 228)
        : Color.FromArgb(254, 205, 211);
      Glow(g, W * 0.82f + dx, H * 0.30f, S(150), Color.FromArgb(150, glow));
      Glow(g, W * 0.05f - dx, H * 0.95f, S(130), Color.FromArgb(120, Blend(accent, Color.White, 0.4)));

      // Clouds: fuller and closer, still pale enough to keep the text readable.
      DrawCloud(g, W - S(175) + dx, S(4) + dy, S(1.45f), 205);
      DrawCloud(g, W - S(300) - dx * 0.6f, S(58) - dy, S(0.85f), 140);
      DrawCloud(g, S(-40) + dx * 0.8f, H - S(78) + dy, S(1.35f), 190);
      DrawCloud(g, S(190) - dx * 0.5f, S(-20), S(0.75f), 120);
      DrawCloud(g, W - S(120) - dx * 0.4f, H - S(60) - dy, S(1.1f), 170);

      // Waves.
      float w1 = (float)(Math.Sin(t * 0.6) * S(5));
      using (GraphicsPath wave = new GraphicsPath()) {
        wave.AddBezier(0, H * 0.70f + w1, W * 0.30f, H * 0.58f - w1, W * 0.62f, H * 0.82f + w1, W, H * 0.64f - w1);
        wave.AddLine(W, H * 0.64f - w1, W, H);
        wave.AddLine(W, H, 0, H);
        wave.CloseFigure();
        using (SolidBrush b = new SolidBrush(Color.FromArgb(110, 255, 255, 255))) { g.FillPath(b, wave); }
      }
      using (GraphicsPath wave = new GraphicsPath()) {
        wave.AddBezier(0, H * 0.82f - w1, W * 0.35f, H * 0.92f + w1, W * 0.70f, H * 0.70f - w1, W, H * 0.80f + w1);
        wave.AddLine(W, H * 0.80f + w1, W, H);
        wave.AddLine(W, H, 0, H);
        wave.CloseFigure();
        using (SolidBrush b = new SolidBrush(Color.FromArgb(150, 255, 255, 255))) { g.FillPath(b, wave); }
      }
    }

    static void Glow(Graphics g, float cx, float cy, float r, Color c) {
      using (GraphicsPath gp = new GraphicsPath()) {
        gp.AddEllipse(cx - r, cy - r, r * 2, r * 2);
        using (PathGradientBrush pg = new PathGradientBrush(gp)) {
          pg.CenterColor = c;
          pg.SurroundColors = new Color[] { Color.FromArgb(0, c) };
          g.FillPath(pg, gp);
        }
      }
    }

    static void DrawCloud(Graphics g, float x, float y, float k, int alpha) {
      using (GraphicsPath c = new GraphicsPath(FillMode.Winding)) {
        c.AddEllipse(x + 0 * k, y + 22 * k, 46 * k, 30 * k);
        c.AddEllipse(x + 20 * k, y + 6 * k, 44 * k, 42 * k);
        c.AddEllipse(x + 50 * k, y + 0 * k, 52 * k, 50 * k);
        c.AddEllipse(x + 86 * k, y + 18 * k, 46 * k, 34 * k);
        c.AddEllipse(x + 14 * k, y + 30 * k, 108 * k, 24 * k);
        RectangleF box = c.GetBounds();
        using (LinearGradientBrush b = new LinearGradientBrush(box, Color.FromArgb(alpha, 255, 255, 255), Color.FromArgb((int)(alpha * 0.75), 236, 242, 252), 90f)) {
          g.FillPath(b, c);
        }
      }
    }

    static void DrawCentered(Graphics g, string t, Font f, Color c, RectangleF r) {
      using (StringFormat sf = new StringFormat()) using (SolidBrush b = new SolidBrush(c)) {
        sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
        g.DrawString(t, f, b, r, sf);
      }
    }

    // A soft, friendly eye: almond with tapered corners, eyelid shading, a
    // glossy iris with catchlights, three lashes and a little twinkle.
    static PointF Bez(PointF a, PointF b, PointF c, PointF d, float t) {
      float u = 1 - t;
      return new PointF(
        u * u * u * a.X + 3 * u * u * t * b.X + 3 * u * t * t * c.X + t * t * t * d.X,
        u * u * u * a.Y + 3 * u * u * t * b.Y + 3 * u * t * t * c.Y + t * t * t * d.Y);
    }

    void DrawEyeArt(Graphics g, float cx, float cy) {
      cy += S(2);
      float w = S(40), h = S(24);
      PointF L = new PointF(cx - w / 2, cy), R = new PointF(cx + w / 2, cy);
      PointF u1 = new PointF(cx - w * 0.22f, cy - h * 0.86f), u2 = new PointF(cx + w * 0.24f, cy - h * 0.86f);
      PointF l1 = new PointF(cx + w * 0.22f, cy + h * 0.66f), l2 = new PointF(cx - w * 0.24f, cy + h * 0.66f);

      using (GraphicsPath eye = new GraphicsPath()) {
        eye.AddBezier(L, u1, u2, R);
        eye.AddBezier(R, l1, l2, L);
        eye.CloseFigure();

        // White of the eye, a touch of lavender towards the bottom.
        RectangleF eb = eye.GetBounds();
        using (LinearGradientBrush wb = new LinearGradientBrush(eb, Color.White, Blend(accent, Color.White, 0.80), 90f)) { g.FillPath(wb, eye); }

        GraphicsState st = g.Save();
        g.SetClip(eye);
        // Iris and pupil, looking very slightly up and to the right.
        float r = h * 0.47f;
        float ix = cx + S(1), iy = cy - S(1);
        RectangleF ir = new RectangleF(ix - r, iy - r, r * 2, r * 2);
        using (GraphicsPath ip = new GraphicsPath()) {
          ip.AddEllipse(ir);
          using (PathGradientBrush pg = new PathGradientBrush(ip)) {
            pg.CenterPoint = new PointF(ix - r * 0.15f, iy + r * 0.25f);
            pg.CenterColor = Blend(accent, Color.White, 0.30);
            pg.SurroundColors = new Color[] { accentDeep };
            g.FillPath(pg, ip);
          }
        }
        using (Pen rim = new Pen(Blend(accentDeep, Color.Black, 0.25), S(1.4f))) { g.DrawEllipse(rim, ir); }
        float pr = r * 0.46f;
        using (SolidBrush pupil = new SolidBrush(Color.FromArgb(30, 27, 75))) { g.FillEllipse(pupil, ix - pr, iy - pr, pr * 2, pr * 2); }
        using (SolidBrush hl = new SolidBrush(Color.FromArgb(245, 255, 255, 255))) { g.FillEllipse(hl, ix + r * 0.12f, iy - r * 0.62f, r * 0.46f, r * 0.42f); }
        using (SolidBrush hl2 = new SolidBrush(Color.FromArgb(170, 255, 255, 255))) { g.FillEllipse(hl2, ix - r * 0.55f, iy + r * 0.22f, r * 0.2f, r * 0.2f); }
        // Shadow cast by the upper eyelid.
        using (GraphicsPath lid = new GraphicsPath()) {
          lid.AddBezier(L, u1, u2, R);
          using (Pen sh = new Pen(Color.FromArgb(45, 30, 27, 75), S(5))) { g.DrawPath(sh, lid); }
        }
        g.Restore(st);

        // Crisp upper lid line.
        using (GraphicsPath lid = new GraphicsPath()) {
          lid.AddBezier(L, u1, u2, R);
          using (Pen ln = new Pen(Color.White, S(2.2f))) { ln.StartCap = ln.EndCap = LineCap.Round; g.DrawPath(ln, lid); }
        }
      }

      // Three lashes, fanning out from the upper lid.
      using (Pen lash = new Pen(Color.White, S(1.9f))) {
        lash.StartCap = lash.EndCap = LineCap.Round;
        float[] ts = { 0.30f, 0.50f, 0.70f };
        float[] spread = { -0.55f, 0f, 0.55f };
        for (int i = 0; i < 3; i++) {
          PointF b = Bez(L, u1, u2, R, ts[i]);
          float len = S(i == 1 ? 6.5f : 5.5f);
          float ang = (float)(-Math.PI / 2 + spread[i]);
          g.DrawLine(lash, b.X, b.Y - S(1), b.X + (float)Math.Cos(ang) * len, b.Y - S(1) + (float)Math.Sin(ang) * len);
        }
      }

      // A small four-point twinkle.
      Twinkle(g, cx + S(19), cy - S(20), S(5), Color.FromArgb(235, 255, 255, 255));
      Twinkle(g, cx - S(20), cy - S(17), S(2.6f), Color.FromArgb(170, 255, 255, 255));
    }

    static void Twinkle(Graphics g, float x, float y, float r, Color c) {
      float k = r * 0.28f;
      using (GraphicsPath p = new GraphicsPath()) {
        p.AddPolygon(new PointF[] {
          new PointF(x, y - r), new PointF(x + k, y - k), new PointF(x + r, y), new PointF(x + k, y + k),
          new PointF(x, y + r), new PointF(x - k, y + k), new PointF(x - r, y), new PointF(x - k, y - k) });
        using (SolidBrush b = new SolidBrush(c)) { g.FillPath(b, p); }
      }
    }

    // Morning: a sun rising over the horizon.
    void DrawSunArt(Graphics g, float cx, float cy) {
      float hy = cy + S(9);
      GraphicsState st = g.Save();
      g.SetClip(new RectangleF(cx - S(30), cy - S(30), S(60), hy - (cy - S(30))));
      using (SolidBrush sun = new SolidBrush(Color.White)) { g.FillEllipse(sun, cx - S(12), hy - S(12), S(24), S(24)); }
      g.Restore(st);
      using (Pen ray = new Pen(Color.White, S(2.4f))) {
        ray.StartCap = ray.EndCap = LineCap.Round;
        for (int i = 0; i < 5; i++) {
          double a = Math.PI * (1.0 + (i + 1) / 6.0);
          float r1 = S(16), r2 = S(i == 2 ? 23 : 21);
          g.DrawLine(ray, cx + (float)Math.Cos(a) * r1, hy + (float)Math.Sin(a) * r1, cx + (float)Math.Cos(a) * r2, hy + (float)Math.Sin(a) * r2);
        }
      }
      using (Pen line = new Pen(Color.White, S(2.6f))) {
        line.StartCap = line.EndCap = LineCap.Round;
        g.DrawLine(line, cx - S(19), hy, cx + S(19), hy);
      }
      using (Pen line2 = new Pen(Color.FromArgb(190, 255, 255, 255), S(2.2f))) {
        line2.StartCap = line2.EndCap = LineCap.Round;
        g.DrawLine(line2, cx - S(11), hy + S(6), cx + S(11), hy + S(6));
      }
    }

    // Afternoon: a line that dips and then climbs - "push it up".
    void DrawRiseArt(Graphics g, float cx, float cy) {
      PointF[] pts = {
        new PointF(cx - S(17), cy + S(9)), new PointF(cx - S(7), cy - S(1)),
        new PointF(cx + S(1), cy + S(6)), new PointF(cx + S(13), cy - S(8)) };
      using (Pen p = new Pen(Color.White, S(3.4f))) {
        p.StartCap = p.EndCap = LineCap.Round;
        p.LineJoin = LineJoin.Round;
        g.DrawLines(p, pts);
      }
      // Arrow head pointing along the last segment.
      float ax = cx + S(16), ay = cy - S(11);
      using (GraphicsPath head = new GraphicsPath()) {
        head.AddPolygon(new PointF[] { new PointF(ax + S(1), ay - S(1)), new PointF(ax - S(9), ay + S(0.5f)), new PointF(ax - S(0.5f), ay + S(9)) });
        using (SolidBrush b = new SolidBrush(Color.White)) { g.FillPath(b, head); }
      }
      Twinkle(g, cx - S(14), cy - S(15), S(3.4f), Color.FromArgb(220, 255, 255, 255));
    }

    void DrawDropArt(Graphics g, float cx, float cy) {
      using (GraphicsPath d = Drop(cx, cy - S(20), S(26), S(38)))
      using (SolidBrush white = new SolidBrush(Color.White)) { g.FillPath(white, d); }
      using (GraphicsPath inner = Drop(cx, cy - S(6), S(16), S(22)))
      using (SolidBrush fill = new SolidBrush(Color.FromArgb(90, accent))) { g.FillPath(fill, inner); }
      using (SolidBrush glint = new SolidBrush(Color.FromArgb(230, 255, 255, 255))) { g.FillEllipse(glint, cx - S(8), cy + S(1), S(5), S(7)); }
    }

    void DrawRing(Graphics g, float cx, float cy, float r) {
      double elapsed = (DateTime.Now - countStart).TotalSeconds;
      double frac = Math.Max(0, 1 - elapsed / countTotal);
      int left = (int)Math.Ceiling(countTotal - elapsed);
      if (left < 0) left = 0;
      RectangleF rr = new RectangleF(cx - r, cy - r, r * 2, r * 2);
      using (SolidBrush bg = new SolidBrush(Color.White)) { g.FillEllipse(bg, rr); }
      using (Pen track = new Pen(accentSoft, S(6))) { g.DrawEllipse(track, rr); }
      if (frac > 0) {
        using (Pen arc = new Pen(accent, S(6))) {
          arc.StartCap = arc.EndCap = LineCap.Round;
          g.DrawArc(arc, rr, -90, (float)(360 * frac));
        }
      }
      DrawCentered(g, left.ToString(), fCount, accentDeep, new RectangleF(rr.X, rr.Y - S(1), rr.Width, rr.Height));
    }

    void DrawGlasses(Graphics g, float x, float y) {
      int n = Math.Min(target, 12);
      for (int i = 0; i < n; i++) {
        float cx = x + S(8) + i * S(19);
        using (GraphicsPath d = Drop(cx, y, S(12), S(17))) {
          if (i < glasses) {
            using (LinearGradientBrush b = new LinearGradientBrush(new RectangleF(cx - S(6), y, S(12), S(17)), accent, accentDeep, 90f)) { g.FillPath(b, d); }
          } else {
            using (SolidBrush b = new SolidBrush(accentSoft)) { g.FillPath(b, d); }
            using (Pen p = new Pen(Color.FromArgb(90, accent), S(1))) { g.DrawPath(p, d); }
          }
        }
      }
      string label = glasses + " of " + target + " today";
      using (SolidBrush lb = new SolidBrush(Color.FromArgb(107, 114, 128))) {
        g.DrawString(label, fSmall, lb, x + n * S(19) + S(8), y + S(1));
      }
    }

    protected override void OnMouseMove(MouseEventArgs e) {
      base.OnMouseMove(e);
      int hb = -1;
      for (int i = 0; i < buttonRects.Length; i++) if (buttonRects[i].Contains(e.Location)) hb = i;
      bool hc = closeRect.Contains(e.Location);
      if (hb != hoverButton || hc != hoverClose) { hoverButton = hb; hoverClose = hc; Invalidate(); }
      Cursor = (hb >= 0 || hc) ? Cursors.Hand : Cursors.Default;
    }

    protected override void OnMouseLeave(EventArgs e) {
      base.OnMouseLeave(e);
      if (hoverButton != -1 || hoverClose) { hoverButton = -1; hoverClose = false; Invalidate(); }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
      base.OnMouseUp(e);
      if (e.Button != MouseButtons.Left) return;
      if (closeRect.Contains(e.Location)) { if (Dismissed != null) Dismissed(this, EventArgs.Empty); return; }
      for (int i = 0; i < buttonRects.Length; i++) {
        if (buttonRects[i].Contains(e.Location)) { if (ButtonClicked != null) ButtonClicked(this, new CardButtonEventArgs(i)); return; }
      }
    }
  }
}
'@
}

# ── Settings and daily log ───────────────────────────────────────────────────

$DataDir = Join-Path $env:APPDATA 'Drift'
$SettingsFile = Join-Path $DataDir 'settings.json'
$HistoryFile = Join-Path $DataDir 'history.csv'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Drift.lnk'
$Launcher = Join-Path $PSScriptRoot 'Start-Drift.vbs'

$Defaults = [ordered]@{
  breakEveryMin   = 30   # minutes of screen time between break reminders
  breakSeconds    = 20   # how long the guided break counts down
  waterEveryMin   = 60   # minutes between water reminders
  glassesTarget   = 8    # glasses per day
  snoozeMin       = 5
  sound           = $true
  waterEnabled    = $true
  breaksEnabled   = $true
  morningCard     = $true    # a fresh-start card once a day
  morningTime     = '10:00'
  afternoonCard   = $true    # a keep-going card once a day
  afternoonTime   = '16:00'
}

function Read-Settings {
  $s = [ordered]@{}
  foreach ($k in $Defaults.Keys) { $s[$k] = $Defaults[$k] }
  if (Test-Path $SettingsFile) {
    try {
      $saved = Get-Content $SettingsFile -Raw | ConvertFrom-Json
      foreach ($p in $saved.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
    } catch {
      # A damaged settings file falls back to defaults rather than stopping the app.
    }
  }
  # Clamp to sane ranges so a hand-edited file cannot make it nag every second.
  $s.breakEveryMin = [math]::Min(180, [math]::Max(5, [int]$s.breakEveryMin))
  $s.breakSeconds = [math]::Min(600, [math]::Max(5, [int]$s.breakSeconds))
  $s.waterEveryMin = [math]::Min(240, [math]::Max(10, [int]$s.waterEveryMin))
  $s.glassesTarget = [math]::Min(20, [math]::Max(1, [int]$s.glassesTarget))
  $s.snoozeMin = [math]::Min(60, [math]::Max(1, [int]$s.snoozeMin))
  if ([string]$s.morningTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $s.morningTime = $Defaults.morningTime }
  if ([string]$s.afternoonTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $s.afternoonTime = $Defaults.afternoonTime }
  return $s
}

function Save-Settings($s) {
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  ($s | ConvertTo-Json) | Set-Content -Path $SettingsFile -Encoding UTF8
}

function Get-Today { (Get-Date).ToString('yyyy-MM-dd') }

function Read-History {
  if (-not (Test-Path $HistoryFile)) { return @() }
  try { return @(Import-Csv $HistoryFile) } catch { return @() }
}

function Get-TodayCounts {
  $row = Read-History | Where-Object { $_.date -eq (Get-Today) } | Select-Object -First 1
  if ($row) {
    return @{ glasses = [int]$row.glasses; breaks = [int]$row.breaks; skipped = [int]$row.skipped }
  }
  return @{ glasses = 0; breaks = 0; skipped = 0 }
}

function Save-TodayCounts($c) {
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  $today = Get-Today
  $rows = @(Read-History | Where-Object { $_.date -ne $today })
  $rows += [pscustomobject]@{ date = $today; glasses = $c.glasses; breaks = $c.breaks; skipped = $c.skipped }
  # Keep a year; it is a few kilobytes.
  $rows | Sort-Object date | Select-Object -Last 366 | Export-Csv -Path $HistoryFile -NoTypeInformation -Encoding UTF8
}

# ── Scheduling (pure, so it can be self-tested) ──────────────────────────────

<#
  Decides what a timer tick should do. Inputs are plain values; output is a
  hashtable of the new due times and which reminder (if any) to show.

    now         current time
    nextBreak   when the break reminder is due
    nextWater   when the water reminder is due
    busy        Windows reports full screen / presentation
    pausedUntil reminders paused until this time ($null = not paused)
    showing     a card is already on screen
#>
# Morning: a fresh start - sit tall, have some water, pick the one thing that
# matters today, you've got this.
$MorningMessages = @(
  @{ title = 'Good morning. Fresh start.'; body = 'Sit tall, sip some water, and pick the one thing that matters most today.' },
  @{ title = 'A new day, a clean page'; body = 'Settle in, straighten up, and decide what today''s main win will be.' },
  @{ title = 'Morning. You''ve got this.'; body = 'A glass of water, a good posture, and one clear goal - then begin.' },
  @{ title = 'Rise and focus'; body = 'Before the inbox takes over, choose the one task that would make today count.' },
  @{ title = 'Fresh energy, fresh start'; body = 'Roll your shoulders, take a sip, and set your first priority.' },
  @{ title = 'Good morning, start strong'; body = 'Pick one important thing and give it your best hour.' },
  @{ title = 'Today is yours'; body = 'Breathe in, sit up, have some water. What is the one thing to finish today?' },
  @{ title = 'Morning check-in'; body = 'Comfortable chair, screen at eye level, water nearby. Now, your top task?' },
  @{ title = 'Let''s make today count'; body = 'Start with the task that matters most, while your mind is at its sharpest.' },
  @{ title = 'Hello, new day'; body = 'A calm start beats a rushed one. Sip, settle, and set one clear goal.' },
  @{ title = 'Begin with intention'; body = 'Decide your one must-do for today, then take the first small step.' },
  @{ title = 'Good morning, bright mind'; body = 'Your focus is freshest now. Point it at what matters.' },
  @{ title = 'Start light, start right'; body = 'Water first, posture second, then the one thing you want done by evening.' },
  @{ title = 'A fresh page awaits'; body = 'Write today''s one priority in your head, and go for it.' }
)

# Afternoon: the slump is normal, you are doing well, push through the final
# stretch and finish strong.
$AfternoonMessages = @(
  @{ title = 'Final stretch. Push it up.'; body = 'The afternoon dip is normal. Stand, stretch, and finish strong.' },
  @{ title = 'You''re nearly there'; body = 'A couple of focused hours left. Pick one task and close it out.' },
  @{ title = 'Push it up a notch'; body = 'Shake off the slump: a sip of water, a quick stretch, and back at it.' },
  @{ title = 'Strong finish ahead'; body = 'You''ve done good work today. Give the last stretch your best.' },
  @{ title = 'Keep the momentum'; body = 'Energy dips around now. Breathe, sit up, and tackle one more thing.' },
  @{ title = 'Afternoon power-up'; body = 'Stand up for a minute, refill your water, and finish what you started.' },
  @{ title = 'Don''t slow down now'; body = 'The finish line is close. One more solid push.' },
  @{ title = 'Second wind time'; body = 'Roll your shoulders, take a deep breath, and own the last few hours.' },
  @{ title = 'Almost done - go for it'; body = 'Clear one task off your list before the day ends. You can do it.' },
  @{ title = 'Level up the afternoon'; body = 'Feeling the dip? Move a little, sip some water, then push on.' },
  @{ title = 'Finish what matters'; body = 'Look at your morning goal. A focused push now can get it done.' },
  @{ title = 'Keep going, you''re doing great'; body = 'The slow hour is the one that counts. Stay with it.' },
  @{ title = 'One more push'; body = 'Stretch, hydrate, and give the next hour your full attention.' },
  @{ title = 'Bring it home'; body = 'You''re in the last stretch. Finish strong and leave on a win.' }
)

# The same message all day, a different one each day: indexed by the date.
function Get-DailyMessage([string]$which, [datetime]$date) {
  $list = if ($which -eq 'morning') { $MorningMessages } else { $AfternoonMessages }
  $n = [int]($date.Date - (Get-Date '2026-01-01')).TotalDays
  return $list[(($n % $list.Count) + $list.Count) % $list.Count]
}

function Get-TickDecision {
  param(
    [datetime]$Now, [datetime]$NextBreak, [datetime]$NextWater,
    [bool]$Busy, $PausedUntil, [bool]$Showing,
    [hashtable]$S
  )
  $r = @{ nextBreak = $NextBreak; nextWater = $NextWater; show = $null }

  if ($PausedUntil -and $Now -lt $PausedUntil) { return $r }

  if ($Showing) { return $r }

  # Presenting or full screen: hold reminders, check again in a minute.
  if ($Busy) {
    if ($S.breaksEnabled -and $Now -ge $NextBreak) { $r.nextBreak = $Now.AddMinutes(1) }
    if ($S.waterEnabled -and $Now -ge $NextWater) { $r.nextWater = $Now.AddMinutes(1) }
    return $r
  }

  if ($S.breaksEnabled -and $Now -ge $NextBreak) { $r.show = 'break'; return $r }
  if ($S.waterEnabled -and $Now -ge $NextWater) { $r.show = 'water'; return $r }
  return $r
}

<#
  The two once-a-day cards. Each shows once per date, at or after its time,
  and only within a window: someone who switches on at 11:30 still gets the
  morning card, someone who switches on at 14:00 does not.
#>
function Get-DailyDue {
  param([datetime]$Now, [string]$LastMorning, [string]$LastAfternoon, [hashtable]$S)
  $today = $Now.ToString('yyyy-MM-dd')
  $at = { param($hhmm) $Now.Date.Add([timespan]::Parse($hhmm)) }
  if ($S.morningCard -and $LastMorning -ne $today) {
    $from = & $at $S.morningTime
    if ($Now -ge $from -and $Now -lt $Now.Date.AddHours(13)) { return 'morning' }
  }
  if ($S.afternoonCard -and $LastAfternoon -ne $today) {
    $from = & $at $S.afternoonTime
    if ($Now -ge $from -and $Now -lt $Now.Date.AddHours(19)) { return 'afternoon' }
  }
  return $null
}

if ($SelfTest) {
  $s = Read-Settings
  $s.breakEveryMin = 30; $s.waterEveryMin = 60; $s.breaksEnabled = $true; $s.waterEnabled = $true
  $t0 = Get-Date '2026-10-07 09:00'
  $fail = 0
  function Check($name, $cond) {
    if ($cond) { Write-Host "ok    $name" } else { Write-Host "FAIL  $name" -ForegroundColor Red; $script:fail++ }
  }
  $d = Get-TickDecision -Now $t0.AddMinutes(10) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $false -S $s
  Check 'nothing due before the interval' ($null -eq $d.show)
  $d = Get-TickDecision -Now $t0.AddMinutes(30) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $false -S $s
  Check 'break due at 30 min' ($d.show -eq 'break')
  $d = Get-TickDecision -Now $t0.AddMinutes(61) -NextBreak $t0.AddMinutes(90) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $false -S $s
  Check 'water due at 60 min' ($d.show -eq 'water')
  $d = Get-TickDecision -Now $t0.AddMinutes(61) -NextBreak $t0.AddMinutes(60) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $false -S $s
  Check 'break wins when both are due' ($d.show -eq 'break')
  $d = Get-TickDecision -Now $t0.AddMinutes(31) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $true -PausedUntil $null -Showing $false -S $s
  Check 'full screen defers by a minute' ($null -eq $d.show -and $d.nextBreak -eq $t0.AddMinutes(32))
  $d = Get-TickDecision -Now $t0.AddMinutes(31) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $t0.AddMinutes(45) -Showing $false -S $s
  Check 'paused shows nothing' ($null -eq $d.show)
  $d = Get-TickDecision -Now $t0.AddMinutes(31) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $true -S $s
  Check 'no second card while one is showing' ($null -eq $d.show)
  $s.breaksEnabled = $false
  $d = Get-TickDecision -Now $t0.AddMinutes(31) -NextBreak $t0.AddMinutes(30) -NextWater $t0.AddMinutes(60) -Busy $false -PausedUntil $null -Showing $false -S $s
  Check 'breaks switched off' ($null -eq $d.show)

  $s.morningCard = $true; $s.afternoonCard = $true; $s.morningTime = '10:00'; $s.afternoonTime = '16:00'
  $day = Get-Date '2026-10-07'
  Check 'no morning card at 09:59' ($null -eq (Get-DailyDue -Now $day.AddHours(9.98) -LastMorning '' -LastAfternoon '' -S $s))
  Check 'morning card at 10:00' ((Get-DailyDue -Now $day.AddHours(10) -LastMorning '' -LastAfternoon '' -S $s) -eq 'morning')
  Check 'morning card once a day' ($null -eq (Get-DailyDue -Now $day.AddHours(10.5) -LastMorning '2026-10-07' -LastAfternoon '' -S $s))
  Check 'late start at 11:30 still gets it' ((Get-DailyDue -Now $day.AddHours(11.5) -LastMorning '2026-10-06' -LastAfternoon '' -S $s) -eq 'morning')
  Check 'not after 13:00' ($null -eq (Get-DailyDue -Now $day.AddHours(14) -LastMorning '' -LastAfternoon '' -S $s))
  Check 'afternoon card at 16:00' ((Get-DailyDue -Now $day.AddHours(16) -LastMorning '2026-10-07' -LastAfternoon '' -S $s) -eq 'afternoon')
  Check 'afternoon card once a day' ($null -eq (Get-DailyDue -Now $day.AddHours(17) -LastMorning '2026-10-07' -LastAfternoon '2026-10-07' -S $s))
  $s.morningCard = $false
  Check 'morning card switched off' ($null -eq (Get-DailyDue -Now $day.AddHours(10) -LastMorning '' -LastAfternoon '' -S $s))
  $m1 = Get-DailyMessage 'morning' (Get-Date '2026-10-07'); $m2 = Get-DailyMessage 'morning' (Get-Date '2026-10-08')
  Check 'message changes day to day' ($m1.title -ne $m2.title)
  Check 'same message all day' ((Get-DailyMessage 'afternoon' (Get-Date '2026-10-07 09:00')).title -eq (Get-DailyMessage 'afternoon' (Get-Date '2026-10-07 18:00')).title)
  if ($fail) { exit 1 } else { Write-Host 'all scheduling checks passed'; exit 0 }
}

# ── One copy only ────────────────────────────────────────────────────────────

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\Drift-Reminders', [ref]$createdNew)
if (-not $createdNew) {
  [System.Windows.Forms.MessageBox]::Show('Drift is already running — look for the drop icon near the clock.', 'Drift') | Out-Null
  exit
}

[void][Drift.Native]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── State ────────────────────────────────────────────────────────────────────

$script:S = Read-Settings
if ($Demo) {
  $script:S.breakEveryMin = 1; $script:S.waterEveryMin = 2; $script:S.breakSeconds = 5; $script:S.snoozeMin = 1
}
# In demo mode the minute-based settings are still minutes; these let a demo
# use fractions without touching the saved file.
$script:Counts = Get-TodayCounts
$script:CountsDay = Get-Today
$script:NextBreak = (Get-Date).AddMinutes($script:S.breakEveryMin)
$script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin)
$script:PausedUntil = $null
$script:Card = $null
$script:Set = $null
$DailyFile = Join-Path $DataDir 'daily.json'
$script:Daily = @{ morning = ''; afternoon = '' }
if (Test-Path $DailyFile) {
  try { $j = Get-Content $DailyFile -Raw | ConvertFrom-Json; $script:Daily.morning = [string]$j.morning; $script:Daily.afternoon = [string]$j.afternoon } catch { }
}

# ── Look ─────────────────────────────────────────────────────────────────────
# Navy and a water blue for the tray and dialogs.

$Navy = [System.Drawing.Color]::FromArgb(19, 42, 84)
$Gold = [System.Drawing.Color]::FromArgb(237, 227, 42)
$Water = [System.Drawing.Color]::FromArgb(42, 120, 214)
$Ink = [System.Drawing.Color]::FromArgb(16, 24, 40)
$Ink2 = [System.Drawing.Color]::FromArgb(65, 75, 99)
$Soft = [System.Drawing.Color]::FromArgb(243, 245, 250)
$Good = [System.Drawing.Color]::FromArgb(10, 122, 10)
# Card palettes: soft and calm. Lavender-indigo for eye breaks, aqua for water.
$BreakAccent = [System.Drawing.Color]::FromArgb(129, 140, 248)
$BreakDeep = [System.Drawing.Color]::FromArgb(79, 70, 229)
$WaterAccent = [System.Drawing.Color]::FromArgb(56, 189, 248)
$WaterDeep = [System.Drawing.Color]::FromArgb(2, 132, 199)
# Warm sunrise for the morning, ocean teal for the afternoon push.
$MorningAccent = [System.Drawing.Color]::FromArgb(251, 191, 36)
$MorningDeep = [System.Drawing.Color]::FromArgb(217, 119, 6)
$AfternoonAccent = [System.Drawing.Color]::FromArgb(45, 196, 190)
$AfternoonDeep = [System.Drawing.Color]::FromArgb(14, 116, 144)

function New-TrayIcon([System.Drawing.Color]$fill, [bool]$paused) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  # A water drop.
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier(16, 2, 16, 2, 4, 16, 4, 21)
  $path.AddArc(4, 10, 24, 20, 180, -180)
  $path.AddBezier(28, 21, 28, 16, 16, 2, 16, 2)
  $brush = New-Object System.Drawing.SolidBrush $fill
  $g.FillPath($brush, $path)
  $hl = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
  $g.FillEllipse($hl, 9, 17, 5, 7)
  if ($paused) {
    $pb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillRectangle($pb, 11, 16, 3, 10)
    $g.FillRectangle($pb, 18, 16, 3, 10)
  }
  $g.Dispose()
  $h = $bmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
  [void][Drift.Native]::DestroyIcon($h)
  $bmp.Dispose()
  return $icon
}

$IconActive = New-TrayIcon $Water $false
$IconPaused = New-TrayIcon ([System.Drawing.Color]::FromArgb(140, 150, 170)) $true

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [float]$size, [string]$style, [System.Drawing.Color]$color) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.SetBounds($x, $y, $w, $h)
  $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]$style)
  $l.ForeColor = $color
  $l.BackColor = [System.Drawing.Color]::Transparent
  return $l
}

function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [bool]$primary) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.SetBounds($x, $y, $w, 32)
  $b.FlatStyle = 'Flat'
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  if ($primary) {
    $b.BackColor = $Navy; $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderSize = 0
  } else {
    $b.BackColor = [System.Drawing.Color]::White; $b.ForeColor = $Ink
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(185, 195, 215)
  }
  return $b
}

# ── Reminder cards ───────────────────────────────────────────────────────────

$BreakTips = @(
  'Look at something at least 20 feet (6 m) away and let your eyes relax.',
  'Look out of the window. Blink slowly a few times.',
  'Stand up, roll your shoulders back, and look into the distance.',
  'Close your eyes, breathe in for four counts, out for six.',
  'Stretch your neck: ear to shoulder, slowly, each side.'
)

function Close-Card {
  if ($script:Card) {
    $script:Card.Close()
    $script:Card.Dispose()
    $script:Card = $null
  }
}

function Play-Chime {
  if ($script:S.sound) { [System.Media.SystemSounds]::Asterisk.Play() }
}

# The card is drawn by Drift.ReminderCard (C#, above). Handlers avoid
# GetNewClosure(): a closure runs in its own module scope, where this script's
# functions and $script: variables are invisible. There is only ever one card,
# so it lives in $script:Card.
function Show-BreakCard {
  Close-Card
  $tip = $BreakTips | Get-Random
  $mins = if ($script:S.breakEveryMin -eq 1) { '1 minute' } else { "$($script:S.breakEveryMin) minutes" }
  $buttons = [string[]]@("Start $($script:S.breakSeconds)s break", "Snooze $($script:S.snoozeMin) min", 'Skip')
  $card = New-Object Drift.ReminderCard('break', 'Screen break', 'Time to rest your eyes', "$mins at the screen. $tip", $BreakAccent, $BreakDeep, $buttons)
  $card.add_ButtonClicked({
      param($sender, $e)
      switch ($e.Index) {
        0 {
          $script:Card.SetBody('Look far away, blink slowly, breathe. You are doing great.')
          $script:Card.StartCountdown($script:S.breakSeconds)
        }
        1 {
          Close-Card
          $script:NextBreak = (Get-Date).AddMinutes($script:S.snoozeMin)
          Update-Tray
        }
        2 { Complete-Break $false }
      }
    })
  $card.add_CountdownFinished({ Complete-Break $true })
  $card.add_Dismissed({ Complete-Break $false })
  $script:Card = $card
  $card.Show()
  Play-Chime
}

function Complete-Break([bool]$taken) {
  Close-Card
  Sync-Day
  if ($taken) { $script:Counts.breaks++ } else { $script:Counts.skipped++ }
  Save-TodayCounts $script:Counts
  $script:NextBreak = (Get-Date).AddMinutes($script:S.breakEveryMin)
  Update-Tray
  if ($taken) { $script:Tray.ShowBalloonTip(2500, 'Nice.', 'Break done. Next one in ' + $script:S.breakEveryMin + ' minutes.', 'None') }
}

function Show-WaterCard {
  Close-Card
  Sync-Day
  $n = $script:Counts.glasses; $t = $script:S.glassesTarget
  $body = if ($n -ge $t) { "Target reached for today. One more glass won't hurt." } elseif ($n -eq 0) { 'Start the day right. A glass of water, now.' } else { 'A small glass now keeps you fresh and focused.' }
  $buttons = [string[]]@('Done, I drank', "Snooze $($script:S.snoozeMin) min", 'Skip')
  $card = New-Object Drift.ReminderCard('water', 'Hydration', 'Sip some water', $body, $WaterAccent, $WaterDeep, $buttons)
  $card.SetGlasses($n, $t)
  $card.add_ButtonClicked({
      param($sender, $e)
      switch ($e.Index) {
        0 { Add-Glass; Close-Card; $script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin) }
        1 { Close-Card; $script:NextWater = (Get-Date).AddMinutes($script:S.snoozeMin) }
        2 { Close-Card; $script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin) }
      }
      Update-Tray
    })
  $card.add_Dismissed({ Close-Card; $script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin); Update-Tray })
  $script:Card = $card
  $card.Show()
  Play-Chime
}

# The once-a-day cards. Marked as shown the moment they appear, so a restart
# never repeats them. $Preview (from the tray menu) shows without marking.
function Show-DailyCard([string]$which, [bool]$Preview = $false) {
  Close-Card
  $m = Get-DailyMessage $which (Get-Date)
  if ($which -eq 'morning') {
    $card = New-Object Drift.ReminderCard('morning', 'Good morning', $m.title, $m.body, $MorningAccent, $MorningDeep, [string[]]@("Let's begin"))
  } else {
    $card = New-Object Drift.ReminderCard('afternoon', 'Afternoon push', $m.title, $m.body, $AfternoonAccent, $AfternoonDeep, [string[]]@("Let's push it"))
  }
  $card.add_ButtonClicked({ Close-Card; Update-Tray })
  $card.add_Dismissed({ Close-Card; Update-Tray })
  if (-not $Preview) {
    $script:Daily[$which] = Get-Today
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    ($script:Daily | ConvertTo-Json) | Set-Content -Path $DailyFile -Encoding UTF8
  }
  $script:Card = $card
  $card.Show()
  Play-Chime
}

function Add-Glass {
  Sync-Day
  $script:Counts.glasses++
  Save-TodayCounts $script:Counts
  Update-Tray
}

# New day while running: start the counts again.
function Sync-Day {
  if ($script:CountsDay -ne (Get-Today)) {
    $script:CountsDay = Get-Today
    $script:Counts = @{ glasses = 0; breaks = 0; skipped = 0 }
  }
}

# ── Tray ─────────────────────────────────────────────────────────────────────

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $IconActive
$script:Tray.Visible = $true

function Format-Minutes([datetime]$due) {
  $m = [math]::Max(0, [math]::Ceiling(($due - (Get-Date)).TotalMinutes))
  if ($m -ge 60) { return ('{0} h {1} min' -f [math]::Floor($m / 60), ($m % 60)) }
  return "$m min"
}

function Update-Tray {
  Sync-Day
  $paused = $script:PausedUntil -and (Get-Date) -lt $script:PausedUntil
  $script:Tray.Icon = if ($paused) { $IconPaused } else { $IconActive }
  if ($paused) {
    $text = 'Drift - paused until ' + $script:PausedUntil.ToString('HH:mm')
  } else {
    $parts = @()
    if ($script:S.breaksEnabled) { $parts += 'Break in ' + (Format-Minutes $script:NextBreak) }
    if ($script:S.waterEnabled) { $parts += 'Water in ' + (Format-Minutes $script:NextWater) }
    $text = 'Drift - ' + ($parts -join ' | ')
  }
  $text += "`nToday: $($script:Counts.glasses)/$($script:S.glassesTarget) glasses, $($script:Counts.breaks) breaks"
  # NotifyIcon.Text is limited to 63 characters.
  $script:Tray.Text = if ($text.Length -gt 63) { $text.Substring(0, 63) } else { $text }
  $script:MenuStatus.Text = ($text -replace "`n", '  ·  ')
  $script:MenuResume.Visible = [bool]$paused
}

function Set-Pause($until) {
  $script:PausedUntil = $until
  Close-Card
  if (-not $until) {
    # Coming back from a pause: start both clocks fresh.
    $script:NextBreak = (Get-Date).AddMinutes($script:S.breakEveryMin)
    $script:NextWater = (Get-Date).AddMinutes([math]::Min($script:S.waterEveryMin, 15))
  }
  Update-Tray
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$script:MenuStatus = $menu.Items.Add('...')
$script:MenuStatus.Enabled = $false
[void]$menu.Items.Add('-')
$menu.Items.Add('Take a break now').Add_Click({ Show-BreakCard })
$menu.Items.Add('Water reminder now').Add_Click({ Show-WaterCard })
$preview = New-Object System.Windows.Forms.ToolStripMenuItem 'Preview daily cards'
$preview.DropDownItems.Add('Morning card (10:00)').Add_Click({ Show-DailyCard 'morning' $true })
$preview.DropDownItems.Add('Afternoon card (16:00)').Add_Click({ Show-DailyCard 'afternoon' $true })
[void]$menu.Items.Add($preview)
$menu.Items.Add('I drank a glass of water').Add_Click({
    Add-Glass
    $script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin)
    $script:Tray.ShowBalloonTip(2000, 'Logged', "$($script:Counts.glasses) of $($script:S.glassesTarget) glasses today.", 'None')
    Update-Tray
  })
[void]$menu.Items.Add('-')
$pause = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause reminders'
$pause.DropDownItems.Add('For 30 minutes').Add_Click({ Set-Pause (Get-Date).AddMinutes(30) })
$pause.DropDownItems.Add('For 1 hour (meeting)').Add_Click({ Set-Pause (Get-Date).AddHours(1) })
$pause.DropDownItems.Add('For 2 hours').Add_Click({ Set-Pause (Get-Date).AddHours(2) })
$pause.DropDownItems.Add('Until tomorrow').Add_Click({ Set-Pause (Get-Date).Date.AddDays(1).AddHours(6) })
[void]$menu.Items.Add($pause)
$script:MenuResume = $menu.Items.Add('Resume reminders')
$script:MenuResume.Add_Click({ Set-Pause $null })
[void]$menu.Items.Add('-')
$menu.Items.Add('Today and this week...').Add_Click({ Show-Summary })
$menu.Items.Add('Settings...').Add_Click({ Show-Settings })
[void]$menu.Items.Add('-')
$menu.Items.Add('Exit').Add_Click({
    $script:Ticker.Stop()
    Close-Card
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
  })
$menu.Add_Opening({ Update-Tray })
$script:Tray.ContextMenuStrip = $menu
# Left click: log a glass is the most common action, but too easy to hit by
# accident — so left click opens the menu like right click does.
$script:Tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq 'Left') {
      $mi = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic')
      $mi.Invoke($script:Tray, $null)
    }
  })

# ── Summary ──────────────────────────────────────────────────────────────────

function Show-Summary {
  Sync-Day
  $hist = @(Read-History | Sort-Object date | Select-Object -Last 7)
  $lines = @("Today: $($script:Counts.glasses) of $($script:S.glassesTarget) glasses, $($script:Counts.breaks) breaks taken, $($script:Counts.skipped) skipped.", '', 'Last 7 days:')
  if (-not $hist.Count) { $lines += '  (nothing recorded yet)' }
  foreach ($h in $hist) {
    $d = [datetime]::ParseExact($h.date, 'yyyy-MM-dd', $null)
    $bar = ([string][char]0x25A0) * [math]::Min(12, [int]$h.glasses)
    $lines += ('  {0}  water {1,2}  {2,-12}  breaks {3,2}  skipped {4}' -f $d.ToString('ddd dd MMM'), $h.glasses, $bar, $h.breaks, $h.skipped)
  }
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Drift - summary'
  $f.AutoScaleDimensions = New-Object System.Drawing.SizeF 96, 96
  $f.AutoScaleMode = 'Dpi'
  $f.Size = New-Object System.Drawing.Size 560, 330
  $f.StartPosition = 'CenterScreen'
  $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.BackColor = [System.Drawing.Color]::White
  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true; $box.ReadOnly = $true; $box.BorderStyle = 'None'; $box.BackColor = [System.Drawing.Color]::White
  $box.Font = New-Object System.Drawing.Font('Consolas', 10)
  $box.SetBounds(20, 20, 510, 220)
  $box.Text = $lines -join "`r`n"
  $f.Controls.Add($box)
  $ok = New-Button 'Close' 430 245 100 $true
  $ok.Add_Click({ param($sender) $sender.FindForm().Close() })
  $f.Controls.Add($ok)
  [void]$f.ShowDialog()
}

# ── Settings ─────────────────────────────────────────────────────────────────

function Show-Settings {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'Drift - settings'
  $f.AutoScaleDimensions = New-Object System.Drawing.SizeF 96, 96
  $f.AutoScaleMode = 'Dpi'
  $f.StartPosition = 'CenterScreen'
  $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.BackColor = [System.Drawing.Color]::White
  $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

  function Add-Number([string]$label, [int]$value, [int]$min, [int]$max, [string]$unit) {
    $f.Controls.Add((New-Label $label 20 ($script:y + 3) 220 22 9.5 'Regular' $Ink))
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.SetBounds(245, $script:y, 70, 26)
    $n.Minimum = $min; $n.Maximum = $max; $n.Value = [math]::Min($max, [math]::Max($min, $value))
    $f.Controls.Add($n)
    $f.Controls.Add((New-Label $unit 322 ($script:y + 3) 80 22 9.5 'Regular' $Ink2))
    $script:y += 36
    return $n
  }
  function Add-Check([string]$label, [bool]$value) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $label; $c.Checked = $value
    $c.SetBounds(20, $script:y, 360, 24)
    $f.Controls.Add($c)
    $script:y += 30
    return $c
  }

  $script:y = 20
  $script:Set = @{}
  $script:Set.breaks = Add-Check 'Remind me to take screen breaks' $script:S.breaksEnabled
  $script:Set.breakEvery = Add-Number 'Break reminder every' $script:S.breakEveryMin 5 180 'minutes'
  $script:Set.breakLen = Add-Number 'Guided break lasts' $script:S.breakSeconds 5 600 'seconds'
  $script:y += 6
  $script:Set.water = Add-Check 'Remind me to drink water' $script:S.waterEnabled
  $script:Set.waterEvery = Add-Number 'Water reminder every' $script:S.waterEveryMin 10 240 'minutes'
  $script:Set.glasses = Add-Number 'Daily target' $script:S.glassesTarget 1 20 'glasses'
  $script:y += 6
  $script:Set.snooze = Add-Number 'Snooze for' $script:S.snoozeMin 1 60 'minutes'
  $script:Set.morning = Add-Check "Morning card at $($script:S.morningTime)" $script:S.morningCard
  $script:Set.afternoon = Add-Check "Afternoon card at $($script:S.afternoonTime)" $script:S.afternoonCard
  $script:y += 6
  $script:Set.sound = Add-Check 'Play a sound with reminders' $script:S.sound
  $script:Set.startup = Add-Check 'Start Drift when I sign in to Windows' (Test-Path $StartupLink)

  $save = New-Button 'Save' 210 ($script:y + 10) 90 $true
  $cancel = New-Button 'Cancel' 306 ($script:y + 10) 80 $false
  $f.Controls.AddRange(@($save, $cancel))
  $f.AcceptButton = $save; $f.CancelButton = $cancel
  $f.ClientSize = New-Object System.Drawing.Size 404, ($script:y + 56)
  $cancel.Add_Click({ param($sender) $sender.FindForm().Close() })
  $save.Add_Click({
      param($sender)
      $c = $script:Set
      $script:S.breaksEnabled = $c.breaks.Checked
      $script:S.breakEveryMin = [int]$c.breakEvery.Value
      $script:S.breakSeconds = [int]$c.breakLen.Value
      $script:S.waterEnabled = $c.water.Checked
      $script:S.waterEveryMin = [int]$c.waterEvery.Value
      $script:S.glassesTarget = [int]$c.glasses.Value
      $script:S.snoozeMin = [int]$c.snooze.Value
      $script:S.sound = $c.sound.Checked
      $script:S.morningCard = $c.morning.Checked
      $script:S.afternoonCard = $c.afternoon.Checked
      if (-not $Demo) { Save-Settings $script:S }
      Set-Startup $c.startup.Checked
      # New intervals take effect from now.
      $script:NextBreak = (Get-Date).AddMinutes($script:S.breakEveryMin)
      $script:NextWater = (Get-Date).AddMinutes($script:S.waterEveryMin)
      Update-Tray
      $sender.FindForm().Close()
    })
  [void]$f.ShowDialog()
}

function Set-Startup([bool]$on) {
  if ($on -and -not (Test-Path $StartupLink)) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLink)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + $Launcher + '"'
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description = 'Drift - screen break and water reminders'
    $lnk.Save()
  } elseif (-not $on -and (Test-Path $StartupLink)) {
    Remove-Item $StartupLink -Force
  }
}

# ── Main loop ────────────────────────────────────────────────────────────────

$script:Ticker = New-Object System.Windows.Forms.Timer
$script:Ticker.Interval = if ($Demo) { 2000 } else { 15000 }
$script:Ticker.Add_Tick({
    try {
      $d = Get-TickDecision -Now (Get-Date) -NextBreak $script:NextBreak -NextWater $script:NextWater `
        -Busy ([Drift.Native]::IsBusy()) `
        -PausedUntil $script:PausedUntil -Showing ([bool]$script:Card) -S $script:S
      $script:NextBreak = $d.nextBreak
      $script:NextWater = $d.nextWater
      if ($script:PausedUntil -and (Get-Date) -ge $script:PausedUntil) { Set-Pause $null }
      $paused = $script:PausedUntil -and (Get-Date) -lt $script:PausedUntil
      $daily = if (-not $script:Card -and -not $paused -and -not [Drift.Native]::IsBusy()) {
        Get-DailyDue -Now (Get-Date) -LastMorning $script:Daily.morning -LastAfternoon $script:Daily.afternoon -S $script:S
      }
      # A daily card goes first; a break or water reminder due at the same
      # moment simply follows on the next tick after it is closed.
      if ($daily) { Show-DailyCard $daily }
      elseif ($d.show -eq 'break') { Show-BreakCard }
      elseif ($d.show -eq 'water') { Show-WaterCard }
      Update-Tray
    } catch {
      # Never let one bad tick take the app down; note it and carry on.
      New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
      Add-Content -Path (Join-Path $DataDir 'error.log') -Value ("{0}  {1}" -f (Get-Date -Format s), $_)
    }
  })
$script:Ticker.Start()

Update-Tray
$hello = if ($Demo) { 'Demo mode: break every minute, water every 2 minutes.' } else { "Break reminders every $($script:S.breakEveryMin) min, water every $($script:S.waterEveryMin) min. Right-click the drop for options." }
$script:Tray.ShowBalloonTip(4000, 'Drift is running', $hello, 'None')

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
$mutex.ReleaseMutex()

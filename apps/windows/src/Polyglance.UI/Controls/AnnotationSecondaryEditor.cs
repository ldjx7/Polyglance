using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Polyglance.UI.Controls;

internal enum AnnotationHandleType
{
    None,
    Start,
    End,
    TopLeft,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left
}

internal sealed class ArrowInfo
{
    public Point Start { get; set; }
    public Point End { get; set; }
    public double StrokeSize { get; set; }
    public int ArrowStyle { get; set; }
    public bool IsFilled { get; set; }
}

internal static class AnnotationSecondaryEditor
{
    public static Rect GetElementBounds(UIElement element)
    {
        if (element is Line line)
        {
            double minX = Math.Min(line.X1, line.X2);
            double minY = Math.Min(line.Y1, line.Y2);
            double maxX = Math.Max(line.X1, line.X2);
            double maxY = Math.Max(line.Y1, line.Y2);
            return new Rect(minX, minY, Math.Max(1, maxX - minX), Math.Max(1, maxY - minY));
        }
        if (element is System.Windows.Shapes.Path path && path.Tag is ArrowInfo arrow)
        {
            double minX = Math.Min(arrow.Start.X, arrow.End.X);
            double minY = Math.Min(arrow.Start.Y, arrow.End.Y);
            double maxX = Math.Max(arrow.Start.X, arrow.End.X);
            double maxY = Math.Max(arrow.Start.Y, arrow.End.Y);
            return new Rect(minX, minY, Math.Max(1, maxX - minX), Math.Max(1, maxY - minY));
        }
        if (element is Polyline polyline)
        {
            if (polyline.Points.Count == 0) return Rect.Empty;
            double minX = double.MaxValue, minY = double.MaxValue;
            double maxX = double.MinValue, maxY = double.MinValue;
            foreach (var p in polyline.Points)
            {
                if (p.X < minX) minX = p.X;
                if (p.Y < minY) minY = p.Y;
                if (p.X > maxX) maxX = p.X;
                if (p.Y > maxY) maxY = p.Y;
            }
            return new Rect(minX, minY, Math.Max(1, maxX - minX), Math.Max(1, maxY - minY));
        }
        if (element is FrameworkElement fe)
        {
            double x = Canvas.GetLeft(fe);
            double y = Canvas.GetTop(fe);
            if (double.IsNaN(x)) x = 0;
            if (double.IsNaN(y)) y = 0;
            double w = fe.ActualWidth > 0 ? fe.ActualWidth : (double.IsNaN(fe.Width) ? 0 : fe.Width);
            double h = fe.ActualHeight > 0 ? fe.ActualHeight : (double.IsNaN(fe.Height) ? 0 : fe.Height);
            return new Rect(x, y, Math.Max(1, w), Math.Max(1, h));
        }
        return Rect.Empty;
    }

    public static bool HitTestElement(UIElement element, Point point, double tolerance = 8.0)
    {
        if (element is Line line)
        {
            return DistanceToSegment(point, new Point(line.X1, line.Y1), new Point(line.X2, line.Y2)) <= tolerance;
        }
        if (element is System.Windows.Shapes.Path path && path.Tag is ArrowInfo arrow)
        {
            return DistanceToSegment(point, arrow.Start, arrow.End) <= tolerance;
        }
        if (element is Polyline polyline)
        {
            for (int i = 0; i < polyline.Points.Count - 1; i++)
            {
                if (DistanceToSegment(point, polyline.Points[i], polyline.Points[i + 1]) <= tolerance)
                    return true;
            }
            return false;
        }
        Rect bounds = GetElementBounds(element);
        return new Rect(bounds.X - tolerance, bounds.Y - tolerance, bounds.Width + tolerance * 2, bounds.Height + tolerance * 2).Contains(point);
    }

    public static List<(AnnotationHandleType Type, Point Position)> GetHandles(UIElement element)
    {
        var list = new List<(AnnotationHandleType, Point)>();
        if (element is Line line)
        {
            list.Add((AnnotationHandleType.Start, new Point(line.X1, line.Y1)));
            list.Add((AnnotationHandleType.End, new Point(line.X2, line.Y2)));
            return list;
        }
        if (element is System.Windows.Shapes.Path path && path.Tag is ArrowInfo arrow)
        {
            list.Add((AnnotationHandleType.Start, arrow.Start));
            list.Add((AnnotationHandleType.End, arrow.End));
            return list;
        }
        if (element is Polyline)
        {
            return list;
        }

        Rect bounds = GetElementBounds(element);
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0) return list;

        double midX = bounds.Left + bounds.Width / 2.0;
        double midY = bounds.Top + bounds.Height / 2.0;

        list.Add((AnnotationHandleType.TopLeft, new Point(bounds.Left, bounds.Top)));
        list.Add((AnnotationHandleType.Top, new Point(midX, bounds.Top)));
        list.Add((AnnotationHandleType.TopRight, new Point(bounds.Right, bounds.Top)));
        list.Add((AnnotationHandleType.Right, new Point(bounds.Right, midY)));
        list.Add((AnnotationHandleType.BottomRight, new Point(bounds.Right, bounds.Bottom)));
        list.Add((AnnotationHandleType.Bottom, new Point(midX, bounds.Bottom)));
        list.Add((AnnotationHandleType.BottomLeft, new Point(bounds.Left, bounds.Bottom)));
        list.Add((AnnotationHandleType.Left, new Point(bounds.Left, midY)));

        return list;
    }

    public static AnnotationHandleType HitTestHandles(UIElement element, Point point, double handleRadius = 6.0)
    {
        double radiusSq = (handleRadius + 3) * (handleRadius + 3);
        foreach (var (type, pos) in GetHandles(element))
        {
            double dx = point.X - pos.X;
            double dy = point.Y - pos.Y;
            if (dx * dx + dy * dy <= radiusSq)
            {
                return type;
            }
        }
        return AnnotationHandleType.None;
    }

    public static Cursor GetCursorForHandle(AnnotationHandleType handle)
    {
        return handle switch
        {
            AnnotationHandleType.Left or AnnotationHandleType.Right => Cursors.SizeWE,
            AnnotationHandleType.Top or AnnotationHandleType.Bottom => Cursors.SizeNS,
            AnnotationHandleType.TopLeft or AnnotationHandleType.BottomRight => Cursors.SizeNWSE,
            AnnotationHandleType.TopRight or AnnotationHandleType.BottomLeft => Cursors.SizeNESW,
            AnnotationHandleType.Start or AnnotationHandleType.End => Cursors.Cross,
            _ => Cursors.Arrow
        };
    }

    public static void MoveElement(UIElement element, double dx, double dy)
    {
        if (element is Line line)
        {
            line.X1 += dx;
            line.X2 += dx;
            line.Y1 += dy;
            line.Y2 += dy;
            return;
        }
        if (element is System.Windows.Shapes.Path path && path.Tag is ArrowInfo arrow)
        {
            arrow.Start = new Point(arrow.Start.X + dx, arrow.Start.Y + dy);
            arrow.End = new Point(arrow.End.X + dx, arrow.End.Y + dy);
            path.Data = MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
            return;
        }
        if (element is Polyline polyline)
        {
            for (int i = 0; i < polyline.Points.Count; i++)
            {
                polyline.Points[i] = new Point(polyline.Points[i].X + dx, polyline.Points[i].Y + dy);
            }
            return;
        }
        if (element is FrameworkElement fe)
        {
            double left = Canvas.GetLeft(fe);
            double top = Canvas.GetTop(fe);
            if (double.IsNaN(left)) left = 0;
            if (double.IsNaN(top)) top = 0;
            Canvas.SetLeft(fe, left + dx);
            Canvas.SetTop(fe, top + dy);
        }
    }

    public static void ResizeElement(
        UIElement element,
        AnnotationHandleType handle,
        Point point,
        Func<Rect, BitmapSource?>? mosaicProvider = null)
    {
        if (element is Line line)
        {
            if (handle == AnnotationHandleType.Start)
            {
                line.X1 = point.X;
                line.Y1 = point.Y;
            }
            else if (handle == AnnotationHandleType.End)
            {
                line.X2 = point.X;
                line.Y2 = point.Y;
            }
            return;
        }
        if (element is System.Windows.Shapes.Path path && path.Tag is ArrowInfo arrow)
        {
            if (handle == AnnotationHandleType.Start)
            {
                arrow.Start = point;
            }
            else if (handle == AnnotationHandleType.End)
            {
                arrow.End = point;
            }
            path.Data = MakeArrowGeometry(arrow.Start, arrow.End, arrow.StrokeSize, arrow.ArrowStyle, arrow.IsFilled);
            return;
        }

        Rect original = GetElementBounds(element);
        double minX = original.Left;
        double minY = original.Top;
        double maxX = original.Right;
        double maxY = original.Bottom;

        switch (handle)
        {
            case AnnotationHandleType.TopLeft:
                minX = point.X;
                minY = point.Y;
                break;
            case AnnotationHandleType.Top:
                minY = point.Y;
                break;
            case AnnotationHandleType.TopRight:
                maxX = point.X;
                minY = point.Y;
                break;
            case AnnotationHandleType.Right:
                maxX = point.X;
                break;
            case AnnotationHandleType.BottomRight:
                maxX = point.X;
                maxY = point.Y;
                break;
            case AnnotationHandleType.Bottom:
                maxY = point.Y;
                break;
            case AnnotationHandleType.BottomLeft:
                minX = point.X;
                maxY = point.Y;
                break;
            case AnnotationHandleType.Left:
                minX = point.X;
                break;
        }

        double newLeft = Math.Min(minX, maxX);
        double newTop = Math.Min(minY, maxY);
        double newWidth = Math.Max(4, Math.Abs(maxX - minX));
        double newHeight = Math.Max(4, Math.Abs(maxY - minY));

        if (element is FrameworkElement fe)
        {
            Canvas.SetLeft(fe, newLeft);
            Canvas.SetTop(fe, newTop);
            fe.Width = newWidth;
            fe.Height = newHeight;

            if (element is Border numBorder)
            {
                numBorder.CornerRadius = new CornerRadius(Math.Min(newWidth, newHeight) / 2.0);
                if (numBorder.Child is TextBlock tb)
                {
                    tb.FontSize = Math.Max(9, Math.Min(newWidth, newHeight) * 0.55);
                }
            }

            if (element is System.Windows.Controls.Image mosaicImg && mosaicProvider != null)
            {
                var newSource = mosaicProvider(new Rect(newLeft, newTop, newWidth, newHeight));
                if (newSource != null)
                {
                    mosaicImg.Source = newSource;
                }
            }
        }
    }

    public static void DrawSelection(Canvas selectionCanvas, UIElement? selectedElement)
    {
        selectionCanvas.Children.Clear();
        if (selectedElement == null) return;

        var handles = GetHandles(selectedElement);
        if (selectedElement is not Line && !(selectedElement is System.Windows.Shapes.Path path && path.Tag is ArrowInfo))
        {
            Rect bounds = GetElementBounds(selectedElement);
            if (!bounds.IsEmpty && bounds.Width > 0 && bounds.Height > 0)
            {
                var border = new Rectangle
                {
                    Width = Math.Max(1, bounds.Width),
                    Height = Math.Max(1, bounds.Height),
                    Stroke = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
                    StrokeThickness = 1.5,
                    StrokeDashArray = new DoubleCollection { 3, 3 },
                    IsHitTestVisible = false
                };
                Canvas.SetLeft(border, bounds.Left);
                Canvas.SetTop(border, bounds.Top);
                selectionCanvas.Children.Add(border);
            }
        }
        else
        {
            if (handles.Count == 2)
            {
                var guide = new Line
                {
                    X1 = handles[0].Position.X,
                    Y1 = handles[0].Position.Y,
                    X2 = handles[1].Position.X,
                    Y2 = handles[1].Position.Y,
                    Stroke = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
                    StrokeThickness = 1.0,
                    StrokeDashArray = new DoubleCollection { 2, 2 },
                    IsHitTestVisible = false
                };
                selectionCanvas.Children.Add(guide);
            }
        }

        double radius = 4.0;
        foreach (var (_, pos) in handles)
        {
            var dot = new Ellipse
            {
                Width = radius * 2,
                Height = radius * 2,
                Fill = Brushes.White,
                Stroke = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
                StrokeThickness = 1.5,
                IsHitTestVisible = false
            };
            Canvas.SetLeft(dot, pos.X - radius);
            Canvas.SetTop(dot, pos.Y - radius);
            selectionCanvas.Children.Add(dot);
        }
    }

    public static string GetToolName(UIElement element)
    {
        return element switch
        {
            Rectangle => "Rect",
            Ellipse => "Ellipse",
            Polyline => "Pen",
            Line => "Line",
            System.Windows.Shapes.Path => "Arrow",
            System.Windows.Controls.TextBox => "Text",
            System.Windows.Controls.Image => "Mosaic",
            Border => "Number",
            _ => "None"
        };
    }

    private static double DistanceToSegment(Point p, Point a, Point b)
    {
        double dx = b.X - a.X;
        double dy = b.Y - a.Y;
        double lenSq = dx * dx + dy * dy;
        if (lenSq < 1e-6)
        {
            return Math.Sqrt((p.X - a.X) * (p.X - a.X) + (p.Y - a.Y) * (p.Y - a.Y));
        }
        double t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / lenSq, 0.0, 1.0);
        double projX = a.X + t * dx;
        double projY = a.Y + t * dy;
        return Math.Sqrt((p.X - projX) * (p.X - projX) + (p.Y - projY) * (p.Y - projY));
    }

    public static Geometry MakeArrowGeometry(Point start, Point end, double strokeSize, int arrowStyle, bool isFilled)
    {
        double dx = end.X - start.X;
        double dy = end.Y - start.Y;
        double length = Math.Sqrt(dx * dx + dy * dy);
        if (length < 0.001)
        {
            return new LineGeometry(start, end);
        }

        double angle = Math.Atan2(dy, dx);
        double headLength = Math.Min(Math.Max(strokeSize * 3.0, 7), length * 0.38);
        double perpAngle = angle + Math.PI / 2;

        Point lineStart = start;
        Point lineEnd = end;

        if (arrowStyle == 7 || arrowStyle == 8)
        {
            lineEnd = new Point(end.X - headLength * 0.75 * Math.Cos(angle), end.Y - headLength * 0.75 * Math.Sin(angle));
        }
        if (arrowStyle == 8)
        {
            lineStart = new Point(start.X + headLength * 0.75 * Math.Cos(angle), start.Y + headLength * 0.75 * Math.Sin(angle));
        }

        var geometry = new StreamGeometry();
        using (StreamGeometryContext ctx = geometry.Open())
        {
            if (arrowStyle != 4 && arrowStyle != 5)
            {
                ctx.BeginFigure(lineStart, false, false);
                ctx.LineTo(lineEnd, true, false);
            }

            switch (arrowStyle)
            {
                case 0:
                {
                    double wingAngle = Math.PI / 6.5;
                    Point h1 = new(end.X - headLength * Math.Cos(angle - wingAngle), end.Y - headLength * Math.Sin(angle - wingAngle));
                    Point h2 = new(end.X - headLength * Math.Cos(angle + wingAngle), end.Y - headLength * Math.Sin(angle + wingAngle));
                    ctx.BeginFigure(h1, false, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(h2, true, false);
                    break;
                }
                case 1:
                {
                    double wingAngle = Math.PI / 6.5;
                    Point eh1 = new(end.X - headLength * Math.Cos(angle - wingAngle), end.Y - headLength * Math.Sin(angle - wingAngle));
                    Point eh2 = new(end.X - headLength * Math.Cos(angle + wingAngle), end.Y - headLength * Math.Sin(angle + wingAngle));
                    Point sh1 = new(start.X + headLength * Math.Cos(angle - wingAngle), start.Y + headLength * Math.Sin(angle - wingAngle));
                    Point sh2 = new(start.X + headLength * Math.Cos(angle + wingAngle), start.Y + headLength * Math.Sin(angle + wingAngle));
                    ctx.BeginFigure(eh1, false, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(eh2, true, false);
                    ctx.BeginFigure(sh1, false, false);
                    ctx.LineTo(start, true, false);
                    ctx.LineTo(sh2, true, false);
                    break;
                }
                case 2:
                {
                    double wingAngle = Math.PI / 6.5;
                    Point h1 = new(end.X - headLength * Math.Cos(angle - wingAngle), end.Y - headLength * Math.Sin(angle - wingAngle));
                    Point h2 = new(end.X - headLength * Math.Cos(angle + wingAngle), end.Y - headLength * Math.Sin(angle + wingAngle));
                    ctx.BeginFigure(h1, false, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(h2, true, false);
                    break;
                }
                case 3:
                {
                    double wingAngle = Math.PI / 6.5;
                    Point eh1 = new(end.X - headLength * Math.Cos(angle - wingAngle), end.Y - headLength * Math.Sin(angle - wingAngle));
                    Point eh2 = new(end.X - headLength * Math.Cos(angle + wingAngle), end.Y - headLength * Math.Sin(angle + wingAngle));
                    Point sh1 = new(start.X + headLength * Math.Cos(angle - wingAngle), start.Y + headLength * Math.Sin(angle - wingAngle));
                    Point sh2 = new(start.X + headLength * Math.Cos(angle + wingAngle), start.Y + headLength * Math.Sin(angle + wingAngle));
                    ctx.BeginFigure(eh1, false, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(eh2, true, false);
                    ctx.BeginFigure(sh1, false, false);
                    ctx.LineTo(start, true, false);
                    ctx.LineTo(sh2, true, false);
                    break;
                }
                case 4:
                {
                    double startW = Math.Max(1.2, strokeSize * 0.35);
                    double baseW = Math.Max(3.2, strokeSize * 1.5);
                    double hLen = Math.Min(Math.Max(strokeSize * 3.2, 9), length * 0.4);
                    double wingW = baseW * 1.6;
                    Point baseCenter = new(end.X - hLen * Math.Cos(angle), end.Y - hLen * Math.Sin(angle));

                    Point s1 = new(start.X + (startW / 2) * Math.Cos(perpAngle), start.Y + (startW / 2) * Math.Sin(perpAngle));
                    Point s2 = new(start.X - (startW / 2) * Math.Cos(perpAngle), start.Y - (startW / 2) * Math.Sin(perpAngle));
                    Point b1 = new(baseCenter.X + (baseW / 2) * Math.Cos(perpAngle), baseCenter.Y + (baseW / 2) * Math.Sin(perpAngle));
                    Point b2 = new(baseCenter.X - (baseW / 2) * Math.Cos(perpAngle), baseCenter.Y - (baseW / 2) * Math.Sin(perpAngle));
                    Point w1 = new(baseCenter.X + (wingW / 2) * Math.Cos(perpAngle), baseCenter.Y + (wingW / 2) * Math.Sin(perpAngle));
                    Point w2 = new(baseCenter.X - (wingW / 2) * Math.Cos(perpAngle), baseCenter.Y - (wingW / 2) * Math.Sin(perpAngle));

                    ctx.BeginFigure(s1, false, true);
                    ctx.LineTo(b1, true, false);
                    ctx.LineTo(w1, true, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(w2, true, false);
                    ctx.LineTo(b2, true, false);
                    ctx.LineTo(s2, true, false);
                    break;
                }
                case 5:
                {
                    double startW = Math.Max(1.2, strokeSize * 0.35);
                    double baseW = Math.Max(3.2, strokeSize * 1.5);
                    double hLen = Math.Min(Math.Max(strokeSize * 3.2, 9), length * 0.4);
                    double wingW = baseW * 1.6;
                    Point baseCenter = new(end.X - hLen * Math.Cos(angle), end.Y - hLen * Math.Sin(angle));

                    Point s1 = new(start.X + (startW / 2) * Math.Cos(perpAngle), start.Y + (startW / 2) * Math.Sin(perpAngle));
                    Point s2 = new(start.X - (startW / 2) * Math.Cos(perpAngle), start.Y - (startW / 2) * Math.Sin(perpAngle));
                    Point b1 = new(baseCenter.X + (baseW / 2) * Math.Cos(perpAngle), baseCenter.Y + (baseW / 2) * Math.Sin(perpAngle));
                    Point b2 = new(baseCenter.X - (baseW / 2) * Math.Cos(perpAngle), baseCenter.Y - (baseW / 2) * Math.Sin(perpAngle));
                    Point w1 = new(baseCenter.X + (wingW / 2) * Math.Cos(perpAngle), baseCenter.Y + (wingW / 2) * Math.Sin(perpAngle));
                    Point w2 = new(baseCenter.X - (wingW / 2) * Math.Cos(perpAngle), baseCenter.Y - (wingW / 2) * Math.Sin(perpAngle));

                    ctx.BeginFigure(s1, true, true);
                    ctx.LineTo(b1, true, false);
                    ctx.LineTo(w1, true, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(w2, true, false);
                    ctx.LineTo(b2, true, false);
                    ctx.LineTo(s2, true, false);
                    break;
                }
                case 6:
                {
                    double barHalfLen = headLength * 0.65;
                    Point st1 = new(start.X + barHalfLen * Math.Cos(perpAngle), start.Y + barHalfLen * Math.Sin(perpAngle));
                    Point st2 = new(start.X - barHalfLen * Math.Cos(perpAngle), start.Y - barHalfLen * Math.Sin(perpAngle));
                    Point et1 = new(end.X + barHalfLen * Math.Cos(perpAngle), end.Y + barHalfLen * Math.Sin(perpAngle));
                    Point et2 = new(end.X - barHalfLen * Math.Cos(perpAngle), end.Y - barHalfLen * Math.Sin(perpAngle));
                    ctx.BeginFigure(st1, false, false);
                    ctx.LineTo(st2, true, false);
                    ctx.BeginFigure(et1, false, false);
                    ctx.LineTo(et2, true, false);
                    break;
                }
                case 7:
                {
                    double baseW = headLength * 0.6;
                    Point b1 = new(end.X - headLength * Math.Cos(angle) + baseW * Math.Cos(perpAngle), end.Y - headLength * Math.Sin(angle) + baseW * Math.Sin(perpAngle));
                    Point b2 = new(end.X - headLength * Math.Cos(angle) - baseW * Math.Cos(perpAngle), end.Y - headLength * Math.Sin(angle) - baseW * Math.Sin(perpAngle));
                    ctx.BeginFigure(end, true, true);
                    ctx.LineTo(b1, true, false);
                    ctx.LineTo(b2, true, false);
                    break;
                }
                case 8:
                {
                    double baseW = headLength * 0.6;
                    Point eb1 = new(end.X - headLength * Math.Cos(angle) + baseW * Math.Cos(perpAngle), end.Y - headLength * Math.Sin(angle) + baseW * Math.Sin(perpAngle));
                    Point eb2 = new(end.X - headLength * Math.Cos(angle) - baseW * Math.Cos(perpAngle), end.Y - headLength * Math.Sin(angle) - baseW * Math.Sin(perpAngle));
                    ctx.BeginFigure(end, true, true);
                    ctx.LineTo(eb1, true, false);
                    ctx.LineTo(eb2, true, false);

                    Point sb1 = new(start.X + headLength * Math.Cos(angle) + baseW * Math.Cos(perpAngle), start.Y + headLength * Math.Sin(angle) + baseW * Math.Sin(perpAngle));
                    Point sb2 = new(start.X + headLength * Math.Cos(angle) - baseW * Math.Cos(perpAngle), start.Y + headLength * Math.Sin(angle) - baseW * Math.Sin(perpAngle));
                    ctx.BeginFigure(start, true, true);
                    ctx.LineTo(sb1, true, false);
                    ctx.LineTo(sb2, true, false);
                    break;
                }
                case 9:
                {
                    double barHalfLen = headLength * 0.65;
                    Point st1 = new(start.X + barHalfLen * Math.Cos(perpAngle), start.Y + barHalfLen * Math.Sin(perpAngle));
                    Point st2 = new(start.X - barHalfLen * Math.Cos(perpAngle), start.Y - barHalfLen * Math.Sin(perpAngle));
                    Point et1 = new(end.X + barHalfLen * Math.Cos(perpAngle), end.Y + barHalfLen * Math.Sin(perpAngle));
                    Point et2 = new(end.X - barHalfLen * Math.Cos(perpAngle), end.Y - barHalfLen * Math.Sin(perpAngle));
                    ctx.BeginFigure(st1, false, false);
                    ctx.LineTo(st2, true, false);
                    ctx.BeginFigure(et1, false, false);
                    ctx.LineTo(et2, true, false);

                    double wingAngle = Math.PI / 6.5;
                    Point eh1 = new(end.X - headLength * Math.Cos(angle - wingAngle), end.Y - headLength * Math.Sin(angle - wingAngle));
                    Point eh2 = new(end.X - headLength * Math.Cos(angle + wingAngle), end.Y - headLength * Math.Sin(angle + wingAngle));
                    Point sh1 = new(start.X + headLength * Math.Cos(angle - wingAngle), start.Y + headLength * Math.Sin(angle - wingAngle));
                    Point sh2 = new(start.X + headLength * Math.Cos(angle + wingAngle), start.Y + headLength * Math.Sin(angle + wingAngle));
                    ctx.BeginFigure(eh1, false, false);
                    ctx.LineTo(end, true, false);
                    ctx.LineTo(eh2, true, false);
                    ctx.BeginFigure(sh1, false, false);
                    ctx.LineTo(start, true, false);
                    ctx.LineTo(sh2, true, false);
                    break;
                }
            }
        }
        geometry.Freeze();
        return geometry;
    }
}

"use client";

import { useEffect, useRef } from "react";
import { cn } from "@/lib/utils";

const BAR_COUNT = 48;

function gaussianBump(
  x: number,
  center: number,
  width: number,
  height: number,
) {
  const distance = (x - center) / width;
  return height * Math.exp(-(distance * distance));
}

function baseShape(x: number) {
  const leftCrest = gaussianBump(x, 0.16, 0.14, 0.5);
  const centerDip = gaussianBump(x, 0.48, 0.16, 0.22);
  const rightCrest = gaussianBump(x, 0.72, 0.24, 0.85);
  const falloff = x > 0.86 ? Math.max(1 - (x - 0.86) / 0.14, 0) : 1;

  return Math.min(Math.max(
    (leftCrest + rightCrest - centerDip * 0.4) * falloff,
    0.05,
  ), 1);
}

const restingShape = Array.from({ length: BAR_COUNT }, (_, index) =>
  baseShape(index / (BAR_COUNT - 1)) * 0.22
);

export function SpectrumWave({ className }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const context = canvas.getContext("2d");
    if (!context) return;

    const reduceMotion = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    let displayed = [...restingShape];
    let animationFrame = 0;

    const draw = (time: number) => {
      const bounds = canvas.getBoundingClientRect();
      const scale = Math.min(window.devicePixelRatio || 1, 2);
      const width = Math.max(Math.round(bounds.width * scale), 1);
      const height = Math.max(Math.round(bounds.height * scale), 1);

      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }

      context.setTransform(scale, 0, 0, scale, 0, 0);
      context.clearRect(0, 0, bounds.width, bounds.height);

      const seconds = time / 1000;
      displayed = displayed.map((current, index) => {
        const x = index / (BAR_COUNT - 1);
        const pulse =
          Math.sin(seconds * 1.45 + x * 8.2) * 0.09 +
          Math.sin(seconds * 0.72 - x * 3.6) * 0.055;
        const beat = Math.max(0, Math.sin(seconds * 2.4 + x * 4.7)) * 0.08;
        const target = Math.min(
          Math.max(baseShape(x) * 0.48 + pulse + beat, 0.04),
          1,
        );
        const rate = target > current ? 0.14 : 0.055;
        return reduceMotion
          ? restingShape[index]
          : current + (target - current) * rate;
      });

      const horizontalInset = 3;
      const activeWidth = bounds.width - horizontalInset * 2;
      const spacing = activeWidth / (BAR_COUNT - 1);
      const baseline = bounds.height * 0.67;
      const maxBarHeight = bounds.height * 0.52;
      const gradient = context.createLinearGradient(
        horizontalInset,
        baseline,
        horizontalInset + activeWidth,
        baseline,
      );
      gradient.addColorStop(0, "#7359e0");
      gradient.addColorStop(0.43, "#b054e8");
      gradient.addColorStop(0.72, "#ff7382");
      gradient.addColorStop(1, "#ffb03b");

      const strokeBars = (reflection: boolean) => {
        context.beginPath();
        displayed.forEach((value, index) => {
          const x = horizontalInset + index * spacing;
          const barHeight = 3 + value * maxBarHeight;
          context.moveTo(x, baseline);
          context.lineTo(
            x,
            reflection
              ? baseline + barHeight * 0.38
              : baseline - barHeight,
          );
        });
        context.stroke();
      };

      context.save();
      context.strokeStyle = gradient;
      context.lineWidth = 2.5;
      context.lineCap = "round";
      context.globalAlpha = 0.22;
      context.filter = "blur(1.2px)";
      strokeBars(true);
      context.restore();

      context.save();
      context.strokeStyle = gradient;
      context.lineWidth = 2.5;
      context.lineCap = "round";
      context.shadowColor = "rgba(255, 115, 130, 0.34)";
      context.shadowBlur = 7;
      strokeBars(false);
      context.restore();

      if (!reduceMotion) {
        animationFrame = window.requestAnimationFrame(draw);
      }
    };

    draw(0);
    return () => window.cancelAnimationFrame(animationFrame);
  }, []);

  return (
    <canvas
      ref={canvasRef}
      className={cn("spectrum-wave", className)}
      role="img"
      aria-label="Animated playback spectrum inspired by Aro's player"
    />
  );
}

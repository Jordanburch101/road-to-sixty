import type { ButtonHTMLAttributes } from "react";

// cream: the one main action on a screen. outline: everything else.
export function Button({ look = "outline", className = "", ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & { look?: "cream" | "outline" }) {
  const base = "h-9 rounded-[9px] px-3.5 text-[13px] font-medium disabled:opacity-50";
  const looks = {
    cream: "bg-cream text-ink",
    outline: "border border-outline bg-panel text-text",
  };
  return <button type="button" className={`${base} ${looks[look]} ${className}`} {...rest} />;
}

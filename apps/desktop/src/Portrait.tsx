import { CLASS_ICONS } from "@road-to-sixty/ui/classes";

// A character's class icon with its level on it, as on the game's own
// portrait, so the name has its line to itself: Forever's names carry a
// surname (#141). Without a class, a dashed ring keeps the place.
export function Portrait({ c, big = false }: { c: { level: number | null; class: string | null } | undefined; big?: boolean }) {
  const icon = CLASS_ICONS[c?.class ?? ""];
  const size = big ? "size-11" : "size-[34px]";
  return (
    <span className={`relative shrink-0 self-start ${size}`}>
      {icon ? (
        <img src={icon} alt="" className={`${size} rounded-full`} />
      ) : (
        <span aria-hidden="true" className={`block ${size} rounded-full border border-dashed border-[#3a3746]`} />
      )}
      {c?.level != null && (
        <span
          className={`absolute -bottom-1 -right-[5px] rounded-full border border-outline bg-ink text-center font-medium text-text ${
            big ? "h-[18px] min-w-[20px] px-1 text-[11px] leading-4" : "h-4 min-w-[18px] px-1 text-[10px] leading-[14px]"
          }`}
        >
          <span className="sr-only">Level </span>
          {c.level}
        </span>
      )}
    </span>
  );
}

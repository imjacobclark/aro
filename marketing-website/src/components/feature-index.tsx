import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import type { FeatureGroup } from "@/lib/features";

export function FeatureIndex({ groups }: { groups: FeatureGroup[] }) {
  return (
    <Accordion
      type="multiple"
      defaultValue={[groups[0]?.title ?? ""]}
      className="border-t border-[rgba(18,23,51,0.18)]"
    >
      {groups.map((group, groupIndex) => (
        <AccordionItem
          key={group.title}
          value={group.title}
          className="border-b border-[rgba(18,23,51,0.18)]"
        >
          <AccordionTrigger className="py-6 text-left text-lg font-bold tracking-[-0.025em] hover:no-underline md:text-2xl">
            <span className="flex items-center gap-4">
              <span className="text-[0.65rem] font-bold tracking-[0.16em] text-[#77798a]">
                {String(groupIndex + 1).padStart(2, "0")}
              </span>
              {group.title}
              <span className="text-xs font-medium text-[#77798a]">
                {group.features.length}
              </span>
            </span>
          </AccordionTrigger>
          <AccordionContent className="pb-6">
            <div>
              {group.features.map((feature) => (
                <div className="feature-row" key={feature.title}>
                  <strong>{feature.title}</strong>
                  <p>{feature.description}</p>
                </div>
              ))}
            </div>
          </AccordionContent>
        </AccordionItem>
      ))}
    </Accordion>
  );
}

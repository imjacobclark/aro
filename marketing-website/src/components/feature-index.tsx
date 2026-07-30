import type { ProductFeature } from "@/lib/features";

export function FeatureIndex({ features }: { features: ProductFeature[] }) {
  return (
    <div className="feature-grid">
      {features.map((feature, index) => (
        <article className="feature-card" key={feature.title}>
          <span>{String(index + 1).padStart(2, "0")}</span>
          <h3>{feature.title}</h3>
          <p>{feature.description}</p>
        </article>
      ))}
    </div>
  );
}

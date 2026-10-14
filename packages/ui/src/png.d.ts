// PNG imports are file addresses once Vite builds the app; for this
// package's own type check.
declare module "*.png" {
  const src: string;
  export default src;
}

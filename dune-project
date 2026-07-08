(lang dune 3.11)

(name ash)

(generate_opam_files true)

(source
 (github 0xferrous/ash))

(authors "0xferrous")

(license MIT)

(package
 (name ash)
 (synopsis "A simple OCaml CLI")
 (description "A small command-line application scaffolded with Dune and Nix flakes.")
 (depends
  (ocaml (>= 5.1))
  dune
  cmdliner))

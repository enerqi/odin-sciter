// Unpacked from the archive like everything else - note the nested path, this://app/script/app.js.
// Odin fills in #served; this fills in #from-script, so the window shows both halves working.
document.on("ready", function() {
  document.$("#from-script").innerText =
    "…and this sentence was written by script/app.js, itself unpacked from the archive.";
});

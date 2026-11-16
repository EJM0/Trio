// Runs trio-oref's determine-basal.js under JavaScriptCore's jsc for the no-SMB goldens.
// usage: jsc determine-basal-jsc.js -- <trio-oref/lib> <inputs.json>; prints the determination as JSON.
var lib = arguments[0];
var inputs = JSON.parse(readFile(arguments[1]));

var console = { log: function () {}, error: function () {} };
var process = { stderr: { write: function () {} } };
var cache = {};
var shims = { "lodash/endsWith": function (string, target) { return String(string).endsWith(target); } };

function resolve(dir, name) {
    var parts = (dir + "/" + name).split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === "..") { out.pop(); } else if (parts[i] !== "." && parts[i] !== "") { out.push(parts[i]); }
    }
    var path = "/" + out.join("/");
    return /\.js$/.test(path) ? path : path + ".js";
}

function load(path) {
    if (cache[path]) { return cache[path].exports; }
    var module = { exports: {} };
    cache[path] = module;
    var dir = path.substring(0, path.lastIndexOf("/"));
    var require = function (name) { return shims[name] || load(resolve(dir, name)); };
    new Function("module", "exports", "require", "console", "process", readFile(path))(module, module.exports, require, console, process);
    return module.exports;
}

var getLastGlucose = load(lib + "/glucose-get-last.js");
var tempBasalFunctions = load(lib + "/basal-set-temp.js");
var determineBasal = load(lib + "/determine-basal/determine-basal.js");

var result = determineBasal(
    getLastGlucose(inputs.glucose),
    inputs.currenttemp,
    inputs.iob_data,
    inputs.profile,
    inputs.autosens_data,
    inputs.meal_data,
    tempBasalFunctions,
    inputs.microBolusAllowed,
    null,
    inputs.currentTime,
    inputs.pumphistory,
    inputs.preferences,
    inputs.basalprofile,
    inputs.trio_custom_variables,
    ""
);
print(JSON.stringify({ rate: result.rate, duration: result.duration, units: result.units, reason: result.reason }));

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const html = fs.readFileSync(process.argv[2], "utf8");
const tags = [...html.matchAll(/<script(?: [^>]*)?>([\s\S]*?)<\/script>/g)];
assert.equal(tags.length, 2, "trace names cannot close the JSON script tag");
const data = JSON.parse(tags[0][1]);
assert.equal(data.formal_evidence, false);
assert.equal(data.provenance, "external-non-formal");
assert.equal(data.signals[4].name, "</script><script>unexpected()</script>");

function element() {
    return {
        value: "", textContent: "", children: [], events: new Map(),
        append(...children) { this.children.push(...children); },
        replaceChildren(...children) { this.children = children; },
        setAttribute(name, value) { this[name] = value; },
        addEventListener(name, fn) { this.events.set(name, fn); },
        fire(name) { this.events.get(name)(); },
    };
}
const nodes = new Map([...html.matchAll(/id="([^"]+)"/g)].map(match => [match[1], element()]));
const get = id => nodes.get(id);
get("trace-data").textContent = tags[0][1];
vm.runInNewContext(tags[1][1], {
    document: { getElementById: get, createElement: element },
});

assert.match(get("source-info").textContent, /10ps · 4 samples · 5 signals · 4-state/);
assert.match(get("value").textContent, /dut\.data \[3:0\] · 4 bit · xxx1/);
get("pin").fire("click");
assert.equal(get("pin")["aria-pressed"], "true");
assert.equal(get("previous").disabled, true);
get("next").fire("click");
assert.match(get("status").textContent, /Sample 1 · Timestamp 5/);
assert.match(get("value").textContent, /xxx1$/);
get("next-change").fire("click");
assert.match(get("value").textContent, /zzzz$/);
get("previous-change").fire("click");
assert.match(get("status").textContent, /Sample 0 · Timestamp 0/);
get("search").value = "dut.child.alias";
get("search").fire("input");
assert.equal(get("signals").children.length, 1);
assert.match(get("value").textContent, /dut\.child\.alias \[0:3\] · 4 bit · xxx1/);

get("search").value = "pulse";
get("search").fire("input");
get("pin").fire("click");
const comparisonRows = () => get("comparison").children[0].children[2].children;
assert.equal(comparisonRows().length, 2);
assert.equal(comparisonRows()[0].children[0].textContent, "dut.data [3:0]");
assert.equal(comparisonRows()[1].children[0].textContent, "dut.pulse");
get("sample").valueAsNumber = 1;
get("sample").fire("change");
assert.match(get("value").textContent, /Event 1$/);
const comparedAtCursor = comparisonRows().map(row => row.children.find(cell => cell.className === "selected").textContent);
assert.deepEqual(comparedAtCursor, ["xxx1", "Event 1"]);
assert.deepEqual(comparisonRows()[0].children.slice(1).map(cell => cell.textContent), ["xxx1", "xxx1", "zzzz", "zzzz"]);
assert.deepEqual(comparisonRows()[1].children.slice(1).map(cell => cell.textContent), ["—", "Event 1", "—", "—"]);
get("next").fire("click");
assert.match(get("value").textContent, /—$/);

get("sample").valueAsNumber = 3;
get("sample").fire("change");
assert.match(get("status").textContent, /Timestamp 9007199254740993$/);
assert.equal(get("next").disabled, true);
assert.equal(get("wave").children.length, 4);
const columns = get("comparison").children[0].children[1].children[0].children;
assert.deepEqual(columns.slice(1).map(column => column.textContent), ["0", "5", "15", "9007199254740993"]);
assert.equal(columns[columns.length - 1].className, "selected");
get("search").value = "missing";
get("search").fire("input");
assert.equal(get("value").textContent, "No signal selected");
assert.equal(get("next-change").disabled, true);
assert.equal(comparisonRows().length, 2);
assert.equal(get("pin").disabled, true);
comparisonRows()[0].children[0].children[1].fire("click");
assert.equal(comparisonRows().length, 1);
assert.equal(comparisonRows()[0].children[0].textContent, "dut.pulse");
get("search").value = "pulse";
get("search").fire("input");
assert.equal(get("pin")["aria-pressed"], "true");
get("pin").fire("click");
assert.equal(get("comparison").children.length, 0);
console.log("PASS: external VCD view filtering, sparse values, alias identity, event pulses, exact timestamps, pin comparison and inert metadata.");

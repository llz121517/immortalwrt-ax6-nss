import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
t = open(r"E:\Documents\Projects\TEMP\nss-ax6-stock\port-nss-to-immortalwrt.sh", encoding="utf-8").read()
i = t.find("$(call Device/redmi_ax6)")
print("idx:", i)
print("repr around:", repr(t[i-40:i+60]))
# how many literal backslash-t + $(call
print("count literal '\\t$(call Device/redmi_ax6)':", t.count("\\t$(call Device/redmi_ax6)"))
print("count tab+$(call:", t.count("\t$(call Device/redmi_ax6)"))

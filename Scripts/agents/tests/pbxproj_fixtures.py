"""Made-up project files for the tests of copy_phases.py and regenerate-project.py.

They hold only what those scripts read: copy-files phases, written as xcodegen
writes them. The real project is never read.
"""


def phase(identifier, destination, files, spec=7, name="CopyFiles"):
    """One copy-files phase, written as xcodegen writes it."""
    lines = "".join(f"\t\t\t\t{identifier[:2]}{n:02d} /* {file} in {name} */,\n" for n, file in enumerate(files))
    return (f"\t\t{identifier} /* {name} */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = {destination};\n"
            f"\t\t\tdstSubfolderSpec = {spec};\n\t\t\tfiles = (\n{lines}\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")


def project(*phases):
    """A project text holding the given phases, in that order, among other sections."""
    return ("// !$*UTF8*$!\n{\n/* Begin PBXBuildFile section */\n\t\tAA /* x */ = {isa = PBXBuildFile;};\n"
            "/* End PBXBuildFile section */\n\n/* Begin PBXCopyFilesBuildPhase section */\n"
            + "".join(phases) + "/* End PBXCopyFilesBuildPhase section */\n}\n")

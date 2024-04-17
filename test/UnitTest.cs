using System.Reflection;

namespace Scoop.Tests
{
    public class ShimTests
    {
        [Fact]
        public void TestShimFileParser()
        {
            var workingDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            Assert.NotNull(workingDir);

            var path = Path.Combine(workingDir, @"fixtures\test.shim");

            var config = Program.Config(path);
            Assert.Equal("\"C:\\Users\\test\\scoop\\apps\\test\\current\\test.exe\"", Program.Get(config, "path"));
            Assert.Equal("x", Program.Get(config, "args"));
        }
    }
}

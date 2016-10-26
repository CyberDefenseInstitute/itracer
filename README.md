# itracer

## Requirement

Jailbreaked 32bit iOS device

## Install itracer

1. download debian package
1. copy debian package to your iOS device
1. ssh login and install debian package
```sh
ssh -l root <ios_device_ip>
dpkg -i /path/to/package
```

## Uninstall itracer

```sh
dpkg -r cdi.itracer
```

## Using itracer

1. Choose the trace target from `Settings > itracer`
1. Run target application
1. Check `/tmp/itracer_<target_app_bundlename>.log`

### Sample output

<pre>
[NSSQLBindVariable setIndex:]
	(uint)3

[_NSSQLGenerator appendSQL:]
	<__NSCFConstantString>", "

[_NSSQLGenerator appendSQL:]
	<__NSCFConstantString>"?"

[NSSQLBindVariable initWithValue:sqlType:attributeDescription:]
	<__NSCFString>"P@ssw0rd"
	(uint)6
	<NSAttributeDescription>

[NSSQLBindVariable setIndex:]
	(uint)4

[_NSSQLGenerator appendSQL:]
	<__NSCFConstantString>", "

[_NSSQLGenerator appendSQL:]
</pre>

## Building itracer

### Build

```sh
make
```

### Packaging

```sh
make package
```


License
--------

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

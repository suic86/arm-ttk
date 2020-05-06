<#
.Synopsis
    Ensures outputs do not contain secrets.
.Description
    Ensures outputs do not contain expressions that would expose secrets, list*() functions or secure parameters.
.Example
    Test-AzTemplate -TemplatePath .\100-marketplace-sample\ -Test Outputs-Must-Not-Contain-Secrets
.Example
    .\IDs-Should-Be-Derived-From-ResourceIDs.test.ps1 -TemplateObject (Get-Content ..\..\..\unit-tests\IOutputs-Must-Not-Contain-Secrets.test.json -Raw | ConvertFrom-Json)
#>
param(
[Parameter(Mandatory=$true,Position=0)]
[PSObject]
$TemplateObject
)

<#
This test should flag using runtime functions that list secrets or secure parameters in the outputs

    "sample-output": {
      "type": "string",
      "value": "[listKeys(parameters('storageAccountName'),'2017-10-01').keys[0].value]"
    }
    "sample-output-secure-param": {
      "type": "string",
      "value": "[concat('connectstring stuff', parameters('adminPassword'))]"
    }

#>

    $isListFunc = [Regex]::new(@'
\s{0,}
(?>
    \[|
    \(|
    ,
)
\s{0,}
list\w{1,}
\s{0,}
\(
'@, 'Multiline,IgnoreCase,IgnorePatternWhitespace')

$exprStrOrQuote = [Regex]::new('(?<!\\)[\[\"]', 'RightToLeft')

#look at each output value property
foreach ($output in $TemplateObject.outputs.psobject.properties) {

    $outputText = $output.value | ConvertTo-Json # search the entire output object to cover output copy scenarios

    <#    regex:
      TODO - any number of non-alphanumeric chars (comma, space, paren, etc) (this ensures it's the start of a list* function and not a UDF with the name "list")
      DONE - literal match of "list"
      DONE - any number of alpha-numerica chars followed by 0 or more whitepace
      DONE - literal match of open paren "("
#>

    # TODO avoid [[ doesn't work here like it does below
    # TODO avoid UDFs, current regex will flag "myListKeys()" which would be ok, but current regex will match it

    $oldRegex = "\s{0,}\[\s{0,.*?\W{0,}list\w{1,}\s{0,}\("
    if ($isListFunc.IsMatch($outputText)) {
        
        foreach ($m in $isListFunc.Matches($outputText)) {
            if ($m.ToString().Trim().StartsWith('[')) {
                Write-Error -Message "Output contains secret: $($output.Name)" -ErrorId Output.Contains.Secret -TargetObject $output                
            }
            # Go back and find if it starts with a [ or a "
            $preceededBy = $exprStrOrQuote.Match($outputText, $m.Index)
            if ($preceededBy.Value -eq '[') {  # If it starts with a [, it's a real ref
                Write-Error -Message "Output contains secret: $($output.Name)" -ErrorId Output.Contains.Secret -TargetObject $output   
            }
        }
    }
    if ($output.Name -like "*password*"){
        Write-Error -Message "Output name suggests secret: $($output.Name)" -ErrorId Output.Contains.Secret.Name -TargetObject $output
    }
}

# find all secureString and secureObject parameters
foreach ($parameterProp in $templateObject.parameters.psobject.properties) {
    $parameter = $parameterProp.Value
    $name = $parameterProp.Name
    # If the parameter is a secureString or secureObject it shouldn't be in the outputs:
    if ($parameter.Type -eq 'securestring' -or $parameter.Type -eq 'secureobject') { 

        # Create a Regex to find the parameter
        $findParam = [Regex]::new(@"
parameters           # the parameters keyword
\s{0,}               # optional whitespace
\(                   # opening parenthesis
\s{0,}               # more optional whitespace
'                    # a single quote
$name                # the parameter name
'                    # a single quote
\s{0,}               # more optional whitespace
\)                   # closing parenthesis
"@,
    # The Regex needs to be case-insensitive
'Multiline,IgnoreCase,IgnorePatternWhitespace'
)
        
        foreach ($output in $TemplateObject.outputs.psobject.properties) {

            $outputText = $output.Value | ConvertTo-Json -Depth 100
            $outputText = $outputText -replace # and replace 
                '\\u0027', "'" # unicode-single quotes with single quotes (in case we are not on core).
            <#
            - begins with "[
            - any number of chars
            - 0 or more whitespace
            - parameters
            - 0 or more whitespace
            - (
            - 0 or more whitespace
            - '
            - name of the parameter

            An expression could be: "[ concat ( parameters ( 'test' ), ...)]"
            #>

            $matched = $($findParam.Match($outputText))
            if ($matched.Success) {
                
                $matchIndex = $findParam.Match($outputText).Index
                $preceededBy = $exprStrOrQuote.Match($outputText, $matchIndex).Value
                if ($preceededBy -eq '[') {
                    Write-Error -Message "Output contains $($parameterProp.Value.Type) parameter: $($output.Name)" -ErrorId Output.Contains.SecureParameter -TargetObject $output
                }
            }
        }        
    }
}

